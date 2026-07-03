import CoreBluetooth
import Foundation

/// Low-level BLE transport for the Equil patch pump.
///
/// Byte-parity reference: AndroidAPS `pump/equil/ble/EquilBLE.kt` + `GattAttributes.kt`.
/// GATT: SERVICE_RADIO = 0000f000-..., single characteristic 0000f001-... used for
/// BOTH write (write-with-response) and notify. CCCD = 00002902-...
///
/// Transport contract mirrors EquilBLE.kt exactly:
///  - On CCCD-notification-enabled (`onReady`) the caller pushes the first command's
///    outgoing packet list and we send them one-by-one, gated by `didWriteValueFor`
///    (with a 20 ms inter-packet delay = EQUIL_BLE_WRITE_TIME_OUT).
///  - Incoming notifications are forwarded verbatim to `onNotify` (the command layer
///    reassembles them via decodeEquilPacket and returns the next packet list, which
///    the caller pushes back through `send(packets:)`).
public final class EquilBLEManager: NSObject {
    // MARK: GATT constants (byte-parity: GattAttributes.kt)

    static let serviceRadio = CBUUID(string: "0000f000-0000-1000-8000-00805f9b34fb")
    static let charUART = CBUUID(string: "0000f001-0000-1000-8000-00805f9b34fb")
    static let cccd = CBUUID(string: "00002902-0000-1000-8000-00805f9b34fb")

    /// EQUIL_BLE_WRITE_TIME_OUT = 20 ms (EquilConst.kt)
    static let writeGapMs: UInt64 = 20

    // MARK: State

    private let queue = DispatchQueue(label: "equil.ble")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    /// A jelenleg kapcsolódott/cél peripheral (watchdog megtartáshoz). nil ha nincs.
    var currentPeripheral: CBPeripheral? { peripheral }
    private var uartChar: CBCharacteristic?

    /// Optional name prefix filter. Equil advertises as "Equil ..." (CmdPair strips
    /// "Equil - " prefix to get the serial). nil = report every named peripheral.
    var nameFilterPrefix: String? = "Equil"

    /// Optional substring filter (AAPS EquilPairSerialNumberFragment uses
    /// `name.contains(serialNumber)` to find the right pump during pairing).
    /// When set, only peripherals whose advertised name contains this string
    /// (case-insensitive) are reported. nil = no substring filtering.
    var nameFilterContains: String?

    /// Outgoing packets pending sequential write; index of next to send.
    private var outgoing: [Data] = []
    private var outIndex = 0

    private(set) var isConnected = false

    // MARK: - BT Watchdog (állandó kapcsolat-tartás + auto force-reconnect)

    /// Ha igaz, a kapcsolat megszakadásakor azonnal újraépítjük (iOS reconnect, scan nélkül).
    var watchdogEnabled = false
    /// Ha igaz, a watchdog auto-reconnect FEL VAN FÜGGESZTVE (parancs-futtatás alatt),
    /// hogy ne versenyezzen a connect-per-command kapcsolatépítéssel (AAPS-modell).
    var watchdogPaused = false
    private var watchdogPeripheralID: UUID?
    private var watchdogTimer: DispatchSourceTimer?

    // MARK: Callbacks (main-thread dispatch is the caller's responsibility)

    var onLog: ((String) -> Void)?
    var onStateChange: ((CBManagerState) -> Void)?
    var onDiscover: ((CBPeripheral, String) -> Void)? // peripheral, name (runner connect-handler)
    /// KÜLÖN diagnosztikai felfedezés-callback (csak listázás, NEM csatlakozik).
    /// A model startScan()-je ezt állítja be, hogy NE írja felül a runner connect-handlerét
    /// (onDiscover), különben a párosítás scan-je felfedez, de sosem csatlakozik.
    var onDiscoverDiagnostic: ((CBPeripheral, String) -> Void)?
    /// Ha igaz, a felfedezésnél CSAK az onDiscoverDiagnostic fut (a runner connect-handlere
    /// szünetel). A diagnosztikai scan kapcsolja be, a párosítás/parancs kikapcsolja.
    var diagnosticOnly = false
    var onConnected: (() -> Void)?
    var onDisconnected: ((Error?) -> Void)?
    /// Fired after CCCD write completes — the pump is ready to receive command packets.
    var onReady: (() -> Void)?
    /// One raw notification frame (16-byte or shorter last packet) from the pump.
    var onNotify: ((Data) -> Void)?

    /// NOTIFY-FLUSH ABLAK: a connect-per-command miatt minden parancs friss
    /// kapcsolaton fut. Az ELŐZŐ parancs utolsó notify-keretei azonban a pumpa
    /// pufferéből átszivároghatnak az ÚJ kapcsolat "notifications enabled -> ready"
    /// eseménye UTÁNRA, és az új parancs első dekódolásánál jelennek meg → ct.len=0B
    /// → Msg1 elveszik → a pumpa a confirm-keretet ismételgeti időtúllépésig
    /// ("temp basal set sem megy", "tartály hiba"). Megoldás: a CCCD engedélyezése
    /// után rövid CSENDESEDÉSI ablakot tartunk; ez alatt a beérkező (maradék) notify
    /// kereteket ELDOBJUK, és csak az ablak végén jelzünk onReady-t (az első write
    /// csak ekkor indul). Így az új parancs tiszta notify-csatornán kezd.
    private var notifyFlushDeadline: Date?
    /// A connect-per-command notify-flush PROFILJA. A három időkonstanst (window / idle-gap /
    /// max-window) innen olvassuk, hogy parancsfajtánként váltható legyen:
    ///  - `.conservative`: bolus/temp/model — lassú pumpa-ürülésre is hagy időt (régi 0,4/0,3/2,0s).
    ///  - `.fastReconnect`: priming fill-loop — a felesleges 2,0s-os max-window-t levágja, DE a
    ///    notify-ablakot NEM viszi 0,5 s ALÁ. A pumpa a StepSet után ~390 ms-enként ismétli a
    ///    confirm-kereteket; ha a következő (Resistance/StepSet) parancs flush-ablaka <0,5 s, stale-
    ///    frame szivárog be → hibás dekódolás/timeout/crash (ezt láttuk a held-opennél). Ezért a
    ///    window-floor (a kvázi-idle minimum) = 0,5 s, a max-window 0,6 s (≥0,5 s, de << 2,0 s).
    ///    Motor/nyomás settle NEM kell (AAPS=0 ms, a resistance pillanatnyi érték).
    /// A profilt a `EquilCommandQueue.runSingleCommand` állítja be a connect ELŐTT.
    public struct NotifyFlushProfile {
        public let window: TimeInterval
        public let idleGap: TimeInterval
        public let maxWindow: TimeInterval
        public init(window: TimeInterval, idleGap: TimeInterval, maxWindow: TimeInterval) {
            self.window = window
            self.idleGap = idleGap
            self.maxWindow = maxWindow
        }

        public static let conservative = NotifyFlushProfile(window: 0.4, idleGap: 0.30, maxWindow: 2.0)
        /// FILL-loop FRISS connect-per-command kapcsolat: a felesleges 2,0s-os max-window-t levágja,
        /// DE a notify-ablakot NEM viszi a BIZTONSÁGOS 0,5 s ALÁ. A pumpa a StepSet után
        /// ~390 ms-enként ismétli a confirm-kereteket; ha a következő (Resistance/StepSet) parancs
        /// flush-ablaka <0,5 s, stale-frame szivárog be → hibás dekódolás/timeout/crash. A GATT-cache
        /// optimalizálással együtt 0,3 s-ra csökkentett ablakot VISSZAÁLLÍTJUK a korábbi biztonságos
        /// értékre: window 0,5 s, max-window 0,6 s. A stabilitás a cél (lépés-idő ~2,85 mp/parancs, OK).
        public static let fastReconnect = NotifyFlushProfile(window: 0.5, idleGap: 0.30, maxWindow: 0.6)
    }

    public var notifyFlushProfile: NotifyFlushProfile = .conservative

    /// A csendesedési ablak hossza (a profilból). A pumpa ismétlési ütemét és a writeGap-et
    /// figyelembe véve elegendő a maradék kiürülésére; fill-loopban rövidebb (fastReconnect).
    private var notifyFlushWindow: TimeInterval { notifyFlushProfile.window }
    /// Igaz a connect pillanatától a window lejártáig. Amíg igaz, MINDEN bejövő
    /// notify-keretet eldobunk (a ready esemény ELŐTT érkező maradékot is).
    private var notifyFlushActive: Bool = false
    /// Token a flush-ablak lezárásához: ha közben ÚJ flush indul, a régi async-záró
    /// nem oldódik ki (megakadályozza a korai ready-t reconnect esetén).
    private var notifyFlushToken: UUID?
    /// IDLE-ZÁRÁS: a fix 400ms-os ablak éppen lejárhat, mielőtt a pumpa utolsó
    /// ismételt maradék-keretét (a ~390ms-os ismétlési ciklusból) megkapnánk, így az
    /// becsúszik a ready UTÁNra és elrontísa az új parancs első dekódolását (ct.len=7B
    /// → a confirm-keret végtelen ismétlődése időtúllépésig: "karikázás", "nincs aktív
    /// temp"). Megoldás: a ready-t NEM fix időre jelezzük, hanem AKKOR, ha a notify-
    /// csatorna ténylegesen elcsendesedett — minden beérkező (eldobott) maradék-keret
    /// ÚJRAINDÍTJA ezt a csendes-időzítőt. A teljes flush-ablak felső korlátja
    /// notifyFlushMaxWindow (hogy néma pumpa esetén se akadjunk el).
    private var notifyFlushIdleGap: TimeInterval { notifyFlushProfile.idleGap }
    /// A flush-ablak abszolút felső korlátja (akkor is zár, ha sose csendesedik el).
    /// Konzervatív profilban 2.0s: a CmdModelSet (futási mód, mode=1) UTÁN a pumpa lassabban
    /// üríti a notify-pufferét, a kisebb hard-deadline a max-window-on zárhatott, MIELŐTT az
    /// utolsó maradék-keret megérkezett (→ "status ciklus beragad"). FILL-loopban (fastReconnect)
    /// 0.5s elég: a friss kapcsolaton a maradékot az idle-zárás + stale-szűrő fogja, így nem
    /// kell minden lépésnél a teljes 2,0s-ot kivárni (ez volt a felesleges ~2 mp/lépés).
    private var notifyFlushMaxWindow: TimeInterval { notifyFlushProfile.maxWindow }
    /// A jelenlegi flush abszolút határideje (a max-window-ból).
    private var notifyFlushHardDeadline: Date?

    /// POST-READY GRACE: a ready jelzése UTÁN még rövid ideig (egy idle-gap) figyeljük,
    /// nem szivárog-e be egy ELŐZŐ parancsból maradt keret. A status-ciklus beragadását
    /// (CmdModelSet után) az okozta, hogy a stale csomag a ready után ~50ms-mal érkezett,
    /// így már az onNotify-ra ment és a dekódoló kontextusát rontotta. Ha grace alatt érkezik
    /// keret, MIELŐTT az új parancs első írása megtörtént (outIndex==0), maradéknak tekintjük
    /// és eldobjuk — a tényleges parancs-válasz csak az első write UTÁN jön.
    private var notifyPostReadyGraceDeadline: Date?
    /// A post-ready grace hossza (egy idle-gap elég a ~390ms-os ismétlési ciklus utolsó
    /// keretének kiszűrésére, anélkül hogy valódi választ késleltetne).
    private let notifyPostReadyGrace: TimeInterval = 0.30

    /// STALE-FRAME SZŰRŐ (ismétlődés-alapú, az outIndex-től függetlenül). A temp basal
    /// cancel→set láncnál a SET friss kapcsolaton fut, de a pumpa az ELŐZŐ (cancel)
    /// parancs notify-kereteit MÉG a SET első write-ja UTÁN is ismételgeti (a logban
    /// 01:34:12.157–16.752, ~4.5s, ugyanaz a 7 keret újra és újra). Az outIndex ekkor már
    /// >0, ezért a post-ready grace nem szűrt, és a stale tartalom a dekódolóba ömlött →
    /// 40s timeout → sárga loop. MEGOLDÁS: a flush + grace alatt LÁTOTT keretek hexjét
    /// eltároljuk; a SET utáni grace-ablakban minden OLYAN keretet eldobunk, amit már
    /// láttunk (= biztosan az előző parancs maradéka, mivel a friss válasz titkosított és
    /// SOHA nem egyezik bitre az előzővel). A teljes stale-áradat így elcsendesedhet, és az
    /// első, korábban NEM látott (valódi) válasz mehet a dekódolóra.
    private var seenStaleFrames: Set<String> = []
    /// A stale-szűrő ablakának felső korlátja a ready után (akkor is felenged, ha a pumpa
    /// sose csendesedik el — ekkor a normál cmdTimeout véd). A láncnál a stale-áradat
    /// ~4.5s, ezért ennél bővebb ablak kell, mint a 0.30s-os grace.
    private var staleFilterDeadline: Date?
    private let staleFilterWindow: TimeInterval = 6.0

    override public init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    // MARK: Public API

    public func startScan() {
        guard central.state == .poweredOn else {
            log("startScan: BT not powered on (state=\(central.state.rawValue))")
            return
        }
        if central.isScanning { central.stopScan() }
        log("startScan")
        // Scan all services — Equil's advertised service list is unreliable across firmware.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    public func stopScan() {
        if central.isScanning {
            central.stopScan()
            log("stopScan")
        }
    }

    public func connect(_ p: CBPeripheral) {
        stopScan()
        peripheral = p
        p.delegate = self
        log("connect -> \(p.name ?? "?")")
        central.connect(p, options: nil)
    }

    public func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        isConnected = false
        uartChar = nil
        outgoing = []
        outIndex = 0
        // Stale-szűrő állapot törlése — a következő friss kapcsolat tiszta lappal indul.
        seenStaleFrames.removeAll(keepingCapacity: true)
        staleFilterDeadline = nil
        notifyPostReadyGraceDeadline = nil
    }

    /// Queue a command's framed packet list and begin sequential transmission.
    /// Mirrors EquilBLE.ready()/writeData(): send send[0], then send[i] after each
    /// onWrite callback. Reset index to 0 before pushing.
    public func send(packets: [Data]) {
        guard !packets.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.outgoing = packets
            self.outIndex = 0
            self.writeNext()
        }
    }

    // MARK: Internal transmit pump

    private func writeNext() {
        guard let p = peripheral, let ch = uartChar else {
            log("writeNext: no peripheral/char — disconnect")
            disconnect()
            return
        }
        guard outIndex < outgoing.count else { return } // all sent
        let data = outgoing[outIndex]
        outIndex += 1
        log("write[\(outIndex)/\(outgoing.count)]: \(data.hexUpper)")
        p.writeValue(data, for: ch, type: .withResponse)
    }

    private func log(_ msg: String) {
        onLog?(msg)
    }
}

// MARK: - CBCentralManagerDelegate

extension EquilBLEManager: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ c: CBCentralManager) {
        log("central state = \(c.state.rawValue)")
        onStateChange?(c.state)
    }

    public func centralManager(
        _: CBCentralManager,
        didDiscover p: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name
        guard let name = advName, !name.isEmpty else { return }
        if let prefix = nameFilterPrefix, !name.hasPrefix(prefix) { return }
        if let needle = nameFilterContains, !needle.isEmpty,
           !name.lowercased().contains(needle.lowercased()) { return }
        log("discover: \(name) rssi=\(RSSI)")
        // Diagnosztikai listázás MINDIG lefut (ha be van kötve).
        onDiscoverDiagnostic?(p, name)
        // A runner connect-handlere CSAK akkor, ha NEM diagnosztikai-only módban vagyunk
        // (azaz párosítás/parancs fut). Így a diagnosztikai scan nem csatlakozik véletlenül,
        // a párosítás scan-je viszont a runner eredeti onDiscover-jét hívja → connect.
        if !diagnosticOnly { onDiscover?(p, name) }
    }

    public func centralManager(_: CBCentralManager, didConnect p: CBPeripheral) {
        isConnected = true
        log("connected; discovering services")
        p.delegate = self
        // NOTIFY-FLUSH ABLAK MÁR ITT NYÍLIK: a maradék notify-keretek (az ELŐZŐ parancsból)
        // gyakran már a "ready" esemény ELŐTT érkeznek be (lásd 05.873 < 05.963 a logban).
        // Ezért a csendesedési ablakot a kapcsolódás pillanatától indítjuk, hogy minden,
        // ami connect és ready között jön, eldobódjon. A ready-t a didUpdateNotificationState
        // hosszabbítja/véglegesíti.
        notifyFlushActive = true
        notifyFlushDeadline = Date().addingTimeInterval(notifyFlushWindow)
        notifyFlushHardDeadline = Date().addingTimeInterval(notifyFlushMaxWindow)
        // Tiszta grace-állapot minden friss kapcsolaton (előző ciklus maradéka ne számítson).
        notifyPostReadyGraceDeadline = nil
        // Stale-szűrő: új kapcsolaton a korábban látott keretek halmaza FRISS — a flush alatt
        // érkező (eldobott) maradek-kereteket gyűjtjük ide, hogy a write után is felismerjük
        // őket, ha a pumpa tovább ismétli (temp cancel→set lánc).
        seenStaleFrames.removeAll(keepingCapacity: true)
        staleFilterDeadline = nil
        // TELJES, MEGBÍZHATÓ DISCOVERY MINDEN RECONNECTNÉL (GATT-cache visszavonva).
        // A connect-per-command modellben a TELJES BLE-bontás után az iOS ÉRVÉNYTELENÍTI a
        // cache-elt CBService/CBCharacteristic referenciákat. A korábbi "ha már fel van
        // fedezve, hagyd ki a discovery-t" cache halott/stale referenciákat használt újra
        // reconnect után → a parancsok nem mentek át, a kapcsolat beragadt, és a
        // deactivate/unpair sem futott le. Ezért MINDEN reconnectnél friss discovery fut
        // (discoverServices → discoverCharacteristics → setNotifyValue), ahogy a cache ELŐTT.
        // A stale uartChar referenciát is eldobjuk, hogy biztosan a frissen felfedezett
        // characteristic-ot használjuk.
        uartChar = nil
        log("connected; discovering services (\(EquilBLEManager.serviceRadio))")
        p.discoverServices([EquilBLEManager.serviceRadio])
        onConnected?()
    }

    public func centralManager(_: CBCentralManager, didFailToConnect _: CBPeripheral, error: Error?) {
        log("didFailToConnect: \(error?.localizedDescription ?? "?")")
        isConnected = false
        onDisconnected?(error)
    }

    public func centralManager(_: CBCentralManager, didDisconnectPeripheral _: CBPeripheral, error: Error?) {
        log("disconnected: \(error?.localizedDescription ?? "clean")")
        isConnected = false
        uartChar = nil
        outgoing = []
        outIndex = 0
        onDisconnected?(error)
        // AAPS connect-per-command modell: a disconnect NORMÁLIS (a pumpa ~11s inaktivitás
        // után magától bont). NINCS auto-reconnect — a következő parancs maga csatlakozik
        // a connectForCommand()-dal. Így nincs watchdog↔parancs kapcsolat-verseny, ami a
        // bólusz 2. üzenetét meghiúsította (a pumpa 10s-os időzítője a parancs kezdetekor indul).
    }
}

// MARK: - CBPeripheralDelegate

extension EquilBLEManager: CBPeripheralDelegate {
    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { log("didDiscoverServices error: \(error)")
            return }
        guard let svc = p.services?.first(where: { $0.uuid == EquilBLEManager.serviceRadio }) else {
            log("SERVICE_RADIO not found")
            return
        }
        p.discoverCharacteristics([EquilBLEManager.charUART], for: svc)
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor svc: CBService, error: Error?) {
        if let error { log("didDiscoverCharacteristics error: \(error)")
            return }
        guard let ch = svc.characteristics?.first(where: { $0.uuid == EquilBLEManager.charUART }) else {
            log("UART char not found")
            return
        }
        uartChar = ch
        log("UART char found; enabling notifications")
        p.setNotifyValue(true, for: ch) // CoreBluetooth writes the CCCD for us
    }

    public func peripheral(_: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        if let error { log("didUpdateNotificationState error: \(error)")
            return }
        guard ch.isNotifying else { return }
        // NOTIFY-FLUSH: a connect óta nyitva tartott csendesedési ablakot innentől MÉG
        // egyszer kinyújtjuk a teljes window-ra, hogy a notify-engedélyezés után érkező
        // maradék kereteket is biztosan eldobjuk. Csak a window LEJÁRTAKOR jelzünk ready-t.
        let myToken = UUID()
        notifyFlushToken = myToken
        notifyFlushActive = true
        notifyFlushDeadline = Date().addingTimeInterval(notifyFlushWindow)
        if notifyFlushHardDeadline == nil {
            notifyFlushHardDeadline = Date().addingTimeInterval(notifyFlushMaxWindow)
        }
        log(
            "notifications enabled -> notify-flush (idle \(Int(notifyFlushIdleGap * 1000))ms / max \(Int(notifyFlushMaxWindow * 1000))ms)"
        )
        // IDLE-ZÁRÁS: az ablakot a teljes window után kezdjük "figyelni", de minden
        // beérkező maradék-keret (didUpdateValueFor) újra-ütemezi a csendes-időzítőt,
        // így a ready garantáltan csak a csatorna tényleges elcsendesedése után jön.
        scheduleFlushIdleCheck(token: myToken, after: notifyFlushWindow)
    }

    /// A flush-ablak idle-alapú lezárója. `after` múlva ellenőrzi: ha közben ÚJ flush
    /// indult (token nem egyezik) → kilép. Ha elértük a hard-deadline-t VAGY az utolsó
    /// maradék-keret óta eltelt az idle-gap → zár + ready. Különben újraütemezi magát.
    private func scheduleFlushIdleCheck(token: UUID, after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.notifyFlushToken == token, self.notifyFlushActive else { return }
            let now = Date()
            let hardReached = (self.notifyFlushHardDeadline.map { now >= $0 }) ?? true
            // notifyFlushDeadline-t minden beérkező maradék-keret előretolja (idle-gap-pel).
            let quietReached = (self.notifyFlushDeadline.map { now >= $0 }) ?? true
            if hardReached || quietReached {
                self.notifyFlushActive = false
                self.notifyFlushDeadline = nil
                self.notifyFlushHardDeadline = nil
                // POST-READY GRACE indítása: a ready után még egy idle-gap-ig figyelünk
                // ELŐZő-parancs maradékra (lásd notifyPostReadyGrace doc). A grace csak
                // addig él, amíg az új parancs első írása el nem indul (outIndex>0).
                self.notifyPostReadyGraceDeadline = Date().addingTimeInterval(self.notifyPostReadyGrace)
                // Stale-szűrő ablak indítása: a ready után a flush alatt látott (= előző parancs)
                // keretek ismétlődéseit a write után is eldobjuk, amíg a stale-áradat el nem csendesedik.
                self.staleFilterDeadline = Date().addingTimeInterval(self.staleFilterWindow)
                self
                    .log(
                        "notify-flush kész (\(hardReached ? "max-window" : "idle")) -> ready (grace \(Int(self.notifyPostReadyGrace * 1000))ms, stale-szűrő \(Int(self.staleFilterWindow * 1000))ms)"
                    )
                self.onReady?()
            } else {
                // Még nem csendesedett el — újra ellenőrizzük a következő idle-gap után.
                self.scheduleFlushIdleCheck(token: token, after: self.notifyFlushIdleGap)
            }
        }
    }

    public func peripheral(_: CBPeripheral, didWriteValueFor _: CBCharacteristic, error: Error?) {
        if let error { log("didWriteValueFor error: \(error)")
            return }
        // EquilBLE.onCharacteristicWrite: sleep(EQUIL_BLE_WRITE_TIME_OUT) then writeData()
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(EquilBLEManager.writeGapMs))) { [weak self] in
            self?.writeNext()
        }
    }

    public func peripheral(_: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if let error { log("didUpdateValueFor error: \(error)")
            return }
        guard let value = ch.value else { return }
        // A csendesedési ablak alatt érkező kereteket eldobjuk (előző parancs maradéka).
        // FONTOS: a notifyFlushActive flag a connect-től a window lejártáig MINDIG igaz,
        // így a ready ELŐTT érkező maradék is biztosan eldobódik (nem csak a deadline-on belül).
        let hex = value.hexUpper
        if notifyFlushActive {
            log("notify (flush, eldobva): \(hex)")
            // Stale-szűrő: a flush alatt látott keretet megjegyezzük, hogy a ready UTÁN is
            // felismerjük, ha a pumpa tovább ismétli (temp cancel→set lánc).
            seenStaleFrames.insert(hex)
            // IDLE-ZÁRÁS: minden eldobott maradék-keret előretolja a csendesedési
            // határidőt, hogy a ready csak az utolsó maradék UTÁN, idle-gap-nyi csend
            // után jöjjön (a hard-deadline a felső korlát).
            notifyFlushDeadline = Date().addingTimeInterval(notifyFlushIdleGap)
            return
        }
        // POST-READY GRACE: ha a ready óta nem telt el a grace, ÉS még nem indult el az
        // új parancs első írása (outIndex==0), akkor ez nem lehet valódi parancs-válasz
        // (a válasz mindig write UTÁN jön) → ELŐZő parancs maradéka, eldobjuk. Így a
        // CmdModelSet után becsúszó stale csomag nem rontja a dekódoló kontextusát.
        if outIndex == 0, let graceUntil = notifyPostReadyGraceDeadline, Date() < graceUntil {
            log("notify (post-ready grace, eldobva): \(hex)")
            seenStaleFrames.insert(hex)
            return
        }
        // STALE-FRAME SZŰRŐ (outIndex-től FÜGGETLEN): a temp cancel→set láncnál a pumpa az
        // előző parancs kereteit a SET első write-ja UTÁN is ismételgeti (outIndex>0). Ha a
        // szűrő-ablakon belül vagyunk ÉS ezt a pontos keretet már láttuk a flush/grace alatt,
        // akkor ez biztosan stale (a friss titkosított válasz SOHA nem egyezik bitre) → eldobjuk,
        // és a szűrő-ablakot előretoljuk, hogy a teljes áradat elcsendesedhessen.
        if let staleUntil = staleFilterDeadline, Date() < staleUntil, seenStaleFrames.contains(hex) {
            log("notify (stale-ismétlődés, eldobva): \(hex)")
            staleFilterDeadline = Date().addingTimeInterval(notifyFlushIdleGap)
            return
        }
        // Az első valódi (korábban nem látott) válasz — a szűrőket lezárjuk és továbbadjuk.
        notifyPostReadyGraceDeadline = nil
        staleFilterDeadline = nil
        log("notify: \(hex)")
        onNotify?(value)
    }
}

// MARK: - Data hex helper (transport logging only)

private extension Data {
    var hexUpper: String { map { String(format: "%02X", $0) }.joined() }
}

// MARK: - BT Watchdog implementáció (állandó kapcsolat + force-reconnect)

//
// iOS-specifikus megközelítés (erősebb mint az AAPS connect-per-command modell):
// a párosított CBPeripheral-t megtartjuk, és central.connect()-tel tartjuk/visszakötjük.
// A connect() timeout NÉLKÜL fut — iOS magától visszaköt, amint a pumpa hatótávba ér,
// új scan nélkül. Ez kiküszöböli a bondolás utáni "nem hirdet újra nevet" scan-race-t,
// ami a bólusz időtúllépést okozta.
public extension EquilBLEManager {
    /// A sikeres párosítás után hívandó: eltárolja és "fogja" a peripheral-t a watchdoghoz.
    func holdPeripheral(_ p: CBPeripheral) {
        watchdogPeripheralID = p.identifier
        peripheral = p
        p.delegate = self
        watchdogEnabled = true
        log("watchdog: peripheral fogva (\(p.name ?? "?")) id=\(p.identifier.uuidString.prefix(8))")
    }

    /// Periodikus őr: ha be van kapcsolva és nincs kapcsolat, reconnect-et kísérel.
    func startWatchdog(intervalSeconds: Int = 3) {
        watchdogTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .seconds(intervalSeconds),
            repeating: .seconds(intervalSeconds)
        )
        timer.setEventHandler { /* watchdog kikapcsolva — AAPS connect-per-command */ }
        watchdogTimer = timer
        // NEM indítjuk el a timert: nincs periodikus reconnect (AAPS-modell).
        log("watchdog: periodikus reconnect KIKAPCSOLVA (connect-per-command)")
    }

    func stopWatchdog() {
        watchdogEnabled = false
        watchdogTimer?.cancel()
        watchdogTimer = nil
        log("watchdog: leállítva")
    }

    /// Azonnali reconnect a megtartott peripheral-hoz (timeout nélkül — iOS hatótáv-figyel).
    func reconnectNow() {
        guard central.state == .poweredOn else {
            log("watchdog: BT nincs poweredOn (\(central.state.rawValue)) — kihagyva")
            return
        }
        guard let p = peripheral else {
            // Talán app-újraindítás után vagyunk: próbáljuk visszakérni az ID alapján.
            if let id = watchdogPeripheralID, retrieveAndHold(identifier: id) {
                log("watchdog: peripheral visszakérve, reconnect…")
                if let pp = peripheral { central.connect(pp, options: nil) }
            } else {
                log("watchdog: nincs megtartott peripheral — reconnect kihagyva")
            }
            return
        }
        if isConnected { return }
        log("watchdog: reconnect kísérlet -> \(p.name ?? "?")")
        central.connect(p, options: [CBConnectPeripheralOptionNotifyOnConnectionKey: true])
    }

    /// App-újraindítás után: a bondolt peripheral visszakérése scan nélkül.
    @discardableResult func retrieveAndHold(identifier: UUID) -> Bool {
        guard let p = central.retrievePeripherals(withIdentifiers: [identifier]).first else {
            return false
        }
        holdPeripheral(p)
        return true
    }

    // MARK: - Connect-per-command (AAPS-modell)

    // A pumpa ~11s inaktivitás után magától bont, ezért NEM tartunk állandó kapcsolatot
    // parancs közben. A bólusz: pause watchdog → friss connect a megtartott peripheral-hoz
    // (scan nélkül) → parancs lefut → resume watchdog. Így nincs scan/reconnect verseny.

    /// Felfüggeszti a watchdog auto-reconnect-jét egy parancs idejére.
    func pauseWatchdog() {
        watchdogPaused = true
        log("watchdog: FELFÜGGESZTVE (parancs-futtatás alatt)")
    }

    /// Visszakapcsolja a watchdog auto-reconnect-jét a parancs után.
    func resumeWatchdog() {
        guard watchdogEnabled else { return }
        watchdogPaused = false
        log("watchdog: FOLYTATVA")
    }

    /// Friss kapcsolatot épít a megtartott peripheral-hoz scan NÉLKÜL (AAPS connectEquil).
    /// Ha már él a kapcsolat, az onConnected-et nem várjuk — a hívó ellenőrzi isConnected-et.
    /// Ha a peripheral elveszett (app-restart), ID alapján visszakéri.
    func connectForCommand() {
        guard central.state == .poweredOn else {
            log("connectForCommand: BT nincs poweredOn (\(central.state.rawValue))")
            return
        }
        // Tiszta induló állapot: minden korábbi kapcsolatot bontunk, hogy a pumpa friss
        // GATT-ot kapjon (a fél-állapotú kapcsolat okozta a néma 10s-os pumpa-bontást).
        if let p = peripheral {
            var didCancelLive = false
            if isConnected {
                log("connectForCommand: bontás a friss kapcsolat előtt")
                central.cancelPeripheralConnection(p)
                isConnected = false
                uartChar = nil
                didCancelLive = true
            }
            stopScan()
            outgoing = []
            outIndex = 0
            peripheral = p
            p.delegate = self
            log("connectForCommand -> \(p.name ?? "?") (scan nélkül)")
            // A 500 ms stack-tisztulási köz CSAK akkor kell, ha MOST bontottunk élő kapcsolatot.
            // A connect-per-command fill-loopban a bontás MÁR megtörtént (EquilCommandQueue.finish),
            // így itt isConnected==false → azonnal csatlakozunk, nincs felesleges 0,5s/lépés várakozás.
            let settle: DispatchTimeInterval = didCancelLive ? .milliseconds(500) : .milliseconds(0)
            queue.asyncAfter(deadline: .now() + settle) { [weak self] in
                guard let self, let pp = self.peripheral else { return }
                self.central.connect(pp, options: nil)
            }
        } else if let id = watchdogPeripheralID, retrieveAndHold(identifier: id) {
            log("connectForCommand: peripheral visszakérve ID alapján")
            if let pp = peripheral {
                queue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
                    self?.central.connect(pp, options: nil)
                }
            }
        } else {
            log("connectForCommand: nincs megtartott peripheral — scan-re esünk vissza")
            startScan()
        }
    }
}
