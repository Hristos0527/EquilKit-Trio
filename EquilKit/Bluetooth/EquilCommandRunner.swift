import CoreBluetooth
import Foundation

/// Drives a single Equil command sequence (pairing or bolus) over the BLE transport.
///
/// Byte-parity reference: AndroidAPS `pump/equil/ble/EquilBLE.kt` orchestration
/// (writeCmd → ready → writeData → onCharacteristicWrite loop, onCharacteristicChanged
/// → decode → writeConf) combined with `EquilManager` command lifecycle.
///
/// Flow:
///   1. Caller builds a command (CmdPair / CmdLargeBasalSet), calls run(command:).
///   2. We reset shared state, connect/scan via EquilBLEManager.
///   3. onReady (CCCD enabled) → command.getEquilResponse() → push packets.
///   4. onNotify(frame) → command.decodeEquilPacket(frame):
///        - returns nil  → waiting for more packets, do nothing.
///        - returns next → push next.send packets.
///   5. When command.cmdSuccess becomes true (or isEnd) → finish(success).
///   6. Timeout guard mirrors EquilConst.EQUIL_CMD_TIME_OUT semantics.
public final class EquilCommandRunner {
    enum Outcome {
        case success(enacted: Bool)
        case failure(String)
    }

    private let ble: EquilBLEManager
    private var command: EquilCommandDriving?
    private var completion: ((Outcome) -> Void)?
    private var finished = false
    private var timeoutWork: DispatchWorkItem?

    /// Forwarded log line (BLE + protocol). Wire to UI/os_log.
    var onLog: ((String) -> Void)?

    /// Párosításkor: a felfedezett (valódi) eszköznévből újraépíti a CmdPair-t,
    /// mert a sorozatszám (sn) a névből származik. Ha nil, a megadott parancs marad.
    var pendingPairFactory: ((_ discoveredName: String) -> EquilCommandDriving)?
    /// A legutóbb futtatott CmdPair (a kialkudott device/password kiolvasásához).
    private(set) var lastPairCommand: CmdPair?

    // MARK: - Többlépéses párosítási flow állapot (AAPS EquilPairSerialNumberFragment)

    /// A felfedezett pump neve+címe (a SN-szűrt scan eredménye).
    private var pairDiscoveredName: String?
    private var pairDiscoveredAddress: String?
    /// A párosítási lépéseket előállító closure-ök (sorrendben).
    /// Mindegyik a felfedezett (name,address) ismeretében épít parancsot, és a
    /// `step(after:)` callback dönti el, lép-e tovább (a parancs eredménye alapján).
    private var pairPipeline: [(_ name: String, _ address: String) -> EquilCommandDriving]?
    private var pairStepIndex = 0
    /// A párosítási flow paraméterei.
    private var pairSerialNumber: String?
    private var pairPassword: String?
    private var pairMaxBolus: Double = 0
    private var pairMaxBasal: Double = 0
    /// A frissen párosított device/password (CmdPair-ből).
    private(set) var pairedDevice: String?
    private(set) var pairedPassword: String?
    /// Pump base firmware from CmdDevicesOldGet (pairing step 1).
    private(set) var pairFirmwareVersion: String = ""
    /// A teljes párosítási flow lezárása.
    private var pairCompletion: ((Outcome) -> Void)?
    /// Igaz, amíg a többlépéses párosítás fut (a single-command finish ezt nem zárja le).
    private var pairingActive = false

    public init(ble: EquilBLEManager) {
        self.ble = ble
        wireBLE()
    }

    private func wireBLE() {
        ble.onLog = { [weak self] in self?.log("[BLE] \($0)") }
        ble.onReady = { [weak self] in self?.handleReady() }
        ble.onNotify = { [weak self] in self?.handleNotify($0) }
        ble.onDisconnected = { [weak self] err in
            guard let self else { return }
            self.log("[BLE] disconnected: \(err?.localizedDescription ?? "clean")")
            // FAIL-FAST: VÁRATLAN drop (err != nil, pl. "The specified device has disconnected
            // from us") AKTÍV parancs közben → azonnal hiba, NE várjuk ki a 30s command-timeoutot.
            // A SZÁNDÉKOS bontás (connect-per-command vége / reconnect előtti cancel) err == nil
            // ("clean") ÉS ilyenkor a parancs már befejeződött (finished==true, command==nil),
            // ezért az NEM fail-fast-ol. A 30s timeout végső védőhálóként megmarad (ha nincs
            // disconnect esemény ÉS nincs válasz). A fail-fast hibát a fill-loop auto-retry kapja el
            // (300ms+ backoff reconnect+resend) → drop esetén ~1–2s recovery, nem 30s stall.
            if err != nil, !self.finished, self.command != nil || self.pairingActive {
                self.log("[BLE] váratlan disconnect aktív parancs közben → fail-fast (azonnali retry)")
                self.finish(.failure("pump disconnected mid-command"))
            }
        }
        ble.onDiscover = { [weak self] peripheral, name in
            guard let self else { return }
            self.log("[BLE] discovered \(name) — connecting")
            // Többlépéses párosítás: rögzítjük a felfedezett nevet+címet (a pipeline
            // ezekből építi a parancsokat). A cím iOS-en a peripheral UUID-ja —
            // ez csak kapcsolat-azonosító, NEM kerül a titkosított payloadba.
            if self.pairingActive {
                self.pairDiscoveredName = name
                self.pairDiscoveredAddress = peripheral.identifier.uuidString
            }
            // Egyparancsos párosítás (régi út): a valódi névből újraépítjük a CmdPair-t.
            if let factory = self.pendingPairFactory {
                let rebuilt = factory(name)
                self.command = rebuilt
                if let pair = rebuilt as? CmdPair { self.lastPairCommand = pair }
                self.pendingPairFactory = nil
            }
            self.ble.connect(peripheral)
        }
    }

    /// Run one command sequence. `timeout` defaults to EQUIL_CMD_TIME_OUT-ish (sane 30s).
    ///
    /// `resetIndices`: alapból igaz (connect-per-command: friss kapcsolat → friss indexek).
    /// A priming fill-loop mindig true-t használ; a párosítási flow saját index-kezeléssel fut.
    func run(
        command: EquilCommandDriving,
        timeout: TimeInterval = 30,
        resetIndices: Bool = true,
        completion: @escaping (Outcome) -> Void
    ) {
        if resetIndices {
            EquilBaseCmd.resetState() // reqIndex/pumpReqIndex/rspIndex → kezdőérték
        }
        self.command = command
        self.completion = completion
        finished = false
        if let pair = command as? CmdPair { lastPairCommand = pair }
        // A log a tényleges útvonalat jelzi. Connect-per-command: friss connect+ready UTÁN
        // `ble.isConnected` igaz, de `resetIndices` mindig true (friss indexek minden parancsnál).
        let connectionLabel: String
        if ble.isConnected {
            connectionLabel = "friss kapcsolat (connect-per-command, scan nélkül)"
        } else {
            connectionLabel = "scanning"
        }
        log("RUN \(command.label) — \(connectionLabel)")
        let heldOpen = ble.isConnected

        let work = DispatchWorkItem { [weak self] in
            self?.finish(.failure("timeout (\(Int(timeout))s)"))
        }
        timeoutWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)

        if heldOpen {
            handleReady() // már kapcsolódva: egyből küldjük az 1. üzenetet
        } else {
            ble.startScan()
        }
    }

    // MARK: - BLE event handlers

    private func handleReady() {
        // A CCCD engedélyezése (onReady) EGYSZER történik a kapcsolat után.
        // Többlépéses párosításnál ekkor indítjuk az ELSŐ lépést (CmdDevicesOldGet).
        if pairingActive, command == nil {
            startPairStep()
            return
        }
        guard let command else { return }
        do {
            let resp = try command.firstResponse()
            log("→ küldés: \(resp.send.count) csomag (1. üzenet)")
            ble.send(packets: resp.send.map { Data($0) })
        } catch {
            finishCommand(.failure("firstResponse error: \(error)"))
        }
    }

    private func handleNotify(_ frame: Data) {
        guard let command, !finished else { return }
        let bytes = [UInt8](frame)
        let next = command.decodeEquilPacket(bytes) // állapotgép

        if command.cmdSuccess {
            log("✓ cmdSuccess (enacted=\(command.enacted))")
            finishCommand(.success(enacted: command.enacted))
            return
        }
        if let next, !next.send.isEmpty {
            log("→ küldés: \(next.send.count) csomag (következő üzenet)")
            ble.send(packets: next.send.map { Data($0) })
        }
        // ha next == nil és nincs cmdSuccess: még gyűlnek a csomagok, várunk
    }

    /// KÜLSŐ MEGSZAKÍTÁS (priming Stop/Cancel, deactivate force-takeover): a folyamatban lévő
    /// parancsot AZONNAL hibára futtatja, hogy a hívó (queue) felszabadulhasson és új parancs
    /// mehessen át. Ha nincs aktív parancs, no-op. A `finish` a normál completion-láncot futtatja
    /// (timeout cancel + completion), így a pipeline tisztán felszabadul.
    func abort() {
        guard !finished, command != nil || pairingActive else { return }
        log("PARANCS MEGSZAKÍTVA (abort) — külső cancel")
        finish(.failure("cancelled"))
    }

    /// Egy parancs (lépés) befejeződött. Többlépéses párosításnál a pipeline-t lépteti,
    /// egyparancsos futtatásnál a teljes flow-t zárja (finish).
    private func finishCommand(_ outcome: Outcome) {
        if pairingActive {
            advancePairing(after: outcome)
        } else {
            finish(outcome)
        }
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        timeoutWork?.cancel()
        timeoutWork = nil
        switch outcome {
        case let .success(enacted): log("BEFEJEZVE: siker (enacted=\(enacted))")
        case let .failure(msg): log("BEFEJEZVE: hiba — \(msg)")
        }
        // Többlépéses párosítás lezárása (pl. időtúllépés a teljes flow-ra).
        let pairCb = pairCompletion
        let singleCb = completion
        resetPairingState()
        completion = nil
        command = nil
        if let pairCb { DispatchQueue.main.async { pairCb(outcome) } }
        else if let singleCb { DispatchQueue.main.async { singleCb(outcome) } }
    }

    private func resetPairingState() {
        pairingActive = false
        pairPipeline = nil
        pairStepIndex = 0
        pairCompletion = nil
        pairDiscoveredName = nil
        pairDiscoveredAddress = nil
        pairSerialNumber = nil
        pairPassword = nil
    }

    private func log(_ msg: String) { onLog?(msg) }

    // MARK: - Többlépéses párosítási flow (AAPS EquilPairSerialNumberFragment-hű)

    //
    //  Sorrend (mind a SAME BLE-kapcsolaton, EGY resetState()-tel az elején):
    //    0) SN-szűrt scan (name.contains(serialNumber)) → connect → CCCD ready
    //    1) CmdDevicesOldGet(address) → siker && isSupport(SN) → vár 500 ms
    //    2) CmdPair(name, address, password) → siker && enacted → vár 500 ms
    //    3) CmdSettingSet(maxBolus, maxBasal) → siker → device/SN mentés
    //
    //  A pumpReqIndex/reqIndex/rspIndex statikus és a teljes flow alatt FOLYAMATOSAN
    //  nő — ezért resetState() csak EGYSZER, a flow elején.
    func runPairing(
        serialNumber: String,
        password: String,
        maxBolus: Double,
        maxBasal: Double,
        timeout: TimeInterval = 90,
        completion: @escaping (Outcome) -> Void
    ) {
        EquilBaseCmd.resetState()
        finished = false
        pairingActive = true
        pairCompletion = completion
        pairSerialNumber = serialNumber
        pairPassword = password
        pairMaxBolus = maxBolus
        pairMaxBasal = maxBasal
        pairStepIndex = 0
        pairedDevice = nil
        pairedPassword = nil
        command = nil

        let now: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
        pairPipeline = [
            // 1) CmdDevicesOldGet — firmware lekérdezés
            { _, address in
                CmdDevicesOldGet(address: address, createTime: now())
            },
            // 2) CmdPair — a sn a felfedezett NÉVBŐL származik
            { [weak self] name, address in
                let pwd = self?.pairPassword ?? password
                let cmd = CmdPair(name: name, address: address, pairPassword: pwd, createTime: now())
                self?.lastPairCommand = cmd
                return cmd
            },
            // 3) CmdSettingSet — a CmdPair-ből kialkudott device/password-del
            { [weak self] _, _ in
                let dev = self?.pairedDevice ?? ""
                let pw = self?.pairedPassword ?? ""
                return CmdSettingSet(
                    maxBolus: maxBolus,
                    maxBasal: maxBasal,
                    equilDevice: dev,
                    equilPassword: pw,
                    createTime: now()
                )
            }
        ]

        log("=== PÁROSÍTÁS (4 lépés) START — SN=\(serialNumber) ===")

        let work = DispatchWorkItem { [weak self] in
            self?.finish(.failure("pairing timeout (\(Int(timeout))s)"))
        }
        timeoutWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)

        ble.nameFilterContains = serialNumber
        if ble.isConnected {
            handleReady()
        } else {
            ble.startScan()
        }
    }

    /// Elindítja az aktuális párosítási lépést (parancs építés + 1. üzenet küldés).
    private func startPairStep() {
        guard let pipeline = pairPipeline, pairStepIndex < pipeline.count else {
            finishPairingSuccess()
            return
        }
        let name = pairDiscoveredName ?? "Equil"
        let address = pairDiscoveredAddress ?? ""
        let cmd = pipeline[pairStepIndex](name, address)
        command = cmd
        log("—— Párosítási lépés \(pairStepIndex + 1)/\(pipeline.count): \(cmd.label) ——")
        do {
            let resp = try cmd.firstResponse()
            log("→ küldés: \(resp.send.count) csomag (lépés 1. üzenet)")
            ble.send(packets: resp.send.map { Data($0) })
        } catch {
            finish(.failure("step \(pairStepIndex + 1) firstResponse error: \(error)"))
        }
    }

    /// Egy párosítási lépés befejeződött — döntés a továbblépésről (AAPS gating).
    private func advancePairing(after outcome: Outcome) {
        guard pairingActive else { return }
        let finishedCmd = command
        command = nil

        guard case let .success(enacted) = outcome else {
            if case let .failure(msg) = outcome { finish(.failure("pairing step error: \(msg)")) }
            return
        }

        switch finishedCmd {
        case let dev as CmdDevicesOldGet:
            let sn = pairSerialNumber ?? ""
            if !dev.isSupport(serialNumber: sn) {
                finish(.failure("unsupported firmware (fw=\(dev.firmwareVersion) < \(EquilConst.EQUIL_SUPPORT_LEVEL))"))
                return
            }
            pairFirmwareVersion = String(format: "%.1f", dev.firmwareVersion)
            log("firmware=\(pairFirmwareVersion) — támogatott")
        case let pair as CmdPair:
            if !enacted {
                finish(.failure("pairing rejected (wrong password or already paired)"))
                return
            }
            pairedDevice = pair.newDevice
            pairedPassword = pair.newPassword
            log("CmdPair OK — device=\(pair.newDevice ?? "?") password=\(pair.newPassword ?? "?")")
        default:
            break // CmdSettingSet: csak siker kell
        }

        pairStepIndex += 1
        guard let pipeline = pairPipeline, pairStepIndex < pipeline.count else {
            finishPairingSuccess()
            return
        }

        let delayMs = Int(EquilConst.EQUIL_BLE_NEXT_CMD)
        log("várakozás \(delayMs) ms a következő lépés előtt")
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
            self?.startPairStep()
        }
    }

    private func finishPairingSuccess() {
        log("=== PÁROSÍTÁS KÉSZ — device/SN menthető ===")
        finish(.success(enacted: true))
    }
}
