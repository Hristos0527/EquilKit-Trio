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

    /// During pairing: rebuilds CmdPair from discovered (actual) device name,
    /// because serial number (sn) comes from name. If nil, supplied command stays.
    var pendingPairFactory: ((_ discoveredName: String) -> EquilCommandDriving)?
    /// Last run CmdPair (to read negotiated device/password).
    private(set) var lastPairCommand: CmdPair?

    // MARK: - Multi-step pairing flow state (AAPS EquilPairSerialNumberFragment)

    /// Discovered pump name+address (SN-filtered scan result).
    private var pairDiscoveredName: String?
    private var pairDiscoveredAddress: String?
    /// Closures producing pairing steps (in order).
    /// Each builds a command from discovered (name,address), and the
    /// `step(after:)` callback decides whether to advance (based on command result).
    private var pairPipeline: [(_ name: String, _ address: String) -> EquilCommandDriving]?
    private var pairStepIndex = 0
    /// Pairing flow parameters.
    private var pairSerialNumber: String?
    private var pairPassword: String?
    private var pairMaxBolus: Double = 0
    private var pairMaxBasal: Double = 0
    /// Freshly paired device/password (from CmdPair).
    private(set) var pairedDevice: String?
    private(set) var pairedPassword: String?
    /// Pump base firmware from CmdDevicesOldGet (pairing step 1).
    private(set) var pairFirmwareVersion: String = ""
    /// Full pairing flow completion.
    private var pairCompletion: ((Outcome) -> Void)?
    /// true while multi-step pairing runs (single-command finish does not clear this).
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
            // FAIL-FAST: UNEXPECTED drop (err != nil, e.g. "The specified device has disconnected
            // from us") during ACTIVE command → fail immediately, do NOT wait 30s command-timeout.
            // INTENTIONAL disconnect (connect-per-command end / pre-reconnect cancel) err == nil
            // ("clean") AND command already finished (finished==true, command==nil),
            // so it does NOT fail-fast. 30s timeout remains final safety net (if no
            // disconnect event AND no response). fill-loop auto-retry catches fail-fast error
            // (300ms+ backoff reconnect+resend) → ~1–2s recovery on drop, not 30s stall.
            if err != nil, !self.finished, self.command != nil || self.pairingActive {
                self.log("[BLE] unexpected disconnect during active command → fail-fast (immediate retry)")
                self.finish(.failure("pump disconnected mid-command"))
            }
        }
        ble.onDiscover = { [weak self] peripheral, name in
            guard let self else { return }
            self.log("[BLE] discovered \(name) — connecting")
            // Multi-step pairing: record discovered name+address (pipeline
            // builds commands from these). On iOS address is peripheral UUID —
            // connection id only, NOT in encrypted payload.
            if self.pairingActive {
                self.pairDiscoveredName = name
                self.pairDiscoveredAddress = peripheral.identifier.uuidString
            }
            // Single-command pairing (legacy): rebuild CmdPair from actual name.
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
    /// `resetIndices`: default true (connect-per-command: fresh connection → fresh indices).
    /// Priming fill-loop always uses true; pairing flow has its own index handling.
    func run(
        command: EquilCommandDriving,
        timeout: TimeInterval = 30,
        resetIndices: Bool = true,
        completion: @escaping (Outcome) -> Void
    ) {
        if resetIndices {
            EquilBaseCmd.resetState() // reqIndex/pumpReqIndex/rspIndex → initial values
        }
        self.command = command
        self.completion = completion
        finished = false
        if let pair = command as? CmdPair { lastPairCommand = pair }
        // Log shows actual path. Connect-per-command: after fresh connect+ready
        // `ble.isConnected` true, but `resetIndices` always true (fresh indices every command).
        let connectionLabel: String
        if ble.isConnected {
            connectionLabel = "fresh connection (connect-per-command, no scan)"
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
            handleReady() // already connected: send 1st message immediately
        } else {
            ble.startScan()
        }
    }

    // MARK: - BLE event handlers

    private func handleReady() {
        // CCCD enable (onReady) happens ONCE after connection.
        // Multi-step pairing starts FIRST step here (CmdDevicesOldGet).
        if pairingActive, command == nil {
            startPairStep()
            return
        }
        guard let command else { return }
        do {
            let resp = try command.firstResponse()
            log("→ send: \(resp.send.count) packet(s) (1st message)")
            ble.send(packets: resp.send.map { Data($0) })
        } catch {
            finishCommand(.failure("firstResponse error: \(error)"))
        }
    }

    private func handleNotify(_ frame: Data) {
        guard let command, !finished else { return }
        let bytes = [UInt8](frame)
        let next = command.decodeEquilPacket(bytes) // state machine

        if command.cmdSuccess {
            log("✓ cmdSuccess (enacted=\(command.enacted))")
            finishCommand(.success(enacted: command.enacted))
            return
        }
        if let next, !next.send.isEmpty {
            log("→ send: \(next.send.count) packet(s) (next message)")
            ble.send(packets: next.send.map { Data($0) })
        }
        // if next == nil and no cmdSuccess: still collecting packets, waiting
    }

    /// EXTERNAL ABORT (priming Stop/Cancel, deactivate force-takeover): immediately fails
    /// in-flight command so caller (queue) can free up and new command
    /// can proceed. No-op if no active command. `finish` runs normal completion chain
    /// (timeout cancel + completion), so pipeline frees cleanly.
    func abort() {
        guard !finished, command != nil || pairingActive else { return }
        log("COMMAND ABORTED (abort) — external cancel")
        finish(.failure("cancelled"))
    }

    /// One command (step) finished. Multi-step pairing advances pipeline,
    /// single-command run closes full flow (finish).
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
        case let .success(enacted): log("DONE: success (enacted=\(enacted))")
        case let .failure(msg): log("DONE: error — \(msg)")
        }
        // Multi-step pairing completion (e.g. full flow timeout).
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

    // MARK: - Multi-step pairing flow (AAPS EquilPairSerialNumberFragment-compatible)

    //
    //  Order (all on SAME BLE connection, ONE resetState() at start):
    //    0) SN-filtered scan (name.contains(serialNumber)) → connect → CCCD ready
    //    1) CmdDevicesOldGet(address) → success && isSupport(SN) → wait 500 ms
    //    2) CmdPair(name, address, password) → success && enacted → wait 500 ms
    //    3) CmdSettingSet(maxBolus, maxBasal) → success → save device/SN
    //
    //  pumpReqIndex/reqIndex/rspIndex are static and CONTINUOUSLY increment
    //  throughout flow — so resetState() only ONCE at flow start.
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
            // 1) CmdDevicesOldGet — firmware query
            { _, address in
                CmdDevicesOldGet(address: address, createTime: now())
            },
            // 2) CmdPair — sn comes from discovered NAME
            { [weak self] name, address in
                let pwd = self?.pairPassword ?? password
                let cmd = CmdPair(name: name, address: address, pairPassword: pwd, createTime: now())
                self?.lastPairCommand = cmd
                return cmd
            },
            // 3) CmdSettingSet — with negotiated device/password from CmdPair
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

        log("=== PAIRING (4 steps) START — SN=\(serialNumber) ===")

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

    /// Starts current pairing step (build command + send 1st message).
    private func startPairStep() {
        guard let pipeline = pairPipeline, pairStepIndex < pipeline.count else {
            finishPairingSuccess()
            return
        }
        let name = pairDiscoveredName ?? "Equil"
        let address = pairDiscoveredAddress ?? ""
        let cmd = pipeline[pairStepIndex](name, address)
        command = cmd
        log("—— Pairing step \(pairStepIndex + 1)/\(pipeline.count): \(cmd.label) ——")
        do {
            let resp = try cmd.firstResponse()
            log("→ send: \(resp.send.count) packet(s) (step 1st message)")
            ble.send(packets: resp.send.map { Data($0) })
        } catch {
            finish(.failure("step \(pairStepIndex + 1) firstResponse error: \(error)"))
        }
    }

    /// Pairing step finished — advance decision (AAPS gating).
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
            log("firmware=\(pairFirmwareVersion) — supported")
        case let pair as CmdPair:
            if !enacted {
                finish(.failure("pairing rejected (wrong password or already paired)"))
                return
            }
            pairedDevice = pair.newDevice
            pairedPassword = pair.newPassword
            log("CmdPair OK — device=\(pair.newDevice ?? "?") password=\(pair.newPassword ?? "?")")
        default:
            break // CmdSettingSet: success only
        }

        pairStepIndex += 1
        guard let pipeline = pairPipeline, pairStepIndex < pipeline.count else {
            finishPairingSuccess()
            return
        }

        let delayMs = Int(EquilConst.EQUIL_BLE_NEXT_CMD)
        log("waiting \(delayMs) ms before next step")
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
            self?.startPairStep()
        }
    }

    private func finishPairingSuccess() {
        log("=== PAIRING DONE — device/SN can be saved ===")
        finish(.success(enacted: true))
    }
}
