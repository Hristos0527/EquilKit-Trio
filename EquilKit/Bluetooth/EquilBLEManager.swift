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
    /// Currently connected/target peripheral (for watchdog retention). nil if none.
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

    // MARK: - BT Watchdog (persistent connection keepalive + auto force-reconnect)

    /// If true, rebuild immediately on disconnect (iOS reconnect, no scan).
    var watchdogEnabled = false
    /// If true, watchdog auto-reconnect is SUSPENDED (during command execution),
    /// so it doesn't race connect-per-command connection setup (AAPS model).
    var watchdogPaused = false
    private var watchdogPeripheralID: UUID?
    private var watchdogTimer: DispatchSourceTimer?

    // MARK: Callbacks (main-thread dispatch is the caller's responsibility)

    var onLog: ((String) -> Void)?
    var onStateChange: ((CBManagerState) -> Void)?
    var onDiscover: ((CBPeripheral, String) -> Void)? // peripheral, name (runner connect-handler)
    /// SEPARATE diagnostic discovery callback (list only, does NOT connect).
    /// Model startScan() sets this so it does NOT override runner connect handler
    /// (onDiscover), otherwise pairing scan discovers but never connects.
    var onDiscoverDiagnostic: ((CBPeripheral, String) -> Void)?
    /// If true, on discovery ONLY onDiscoverDiagnostic runs (runner connect handler
    /// paused). Diagnostic scan enables it, pairing/command disables it.
    var diagnosticOnly = false
    var onConnected: (() -> Void)?
    var onDisconnected: ((Error?) -> Void)?
    /// Fired after CCCD write completes — the pump is ready to receive command packets.
    var onReady: (() -> Void)?
    /// One raw notification frame (16-byte or shorter last packet) from the pump.
    var onNotify: ((Data) -> Void)?

    /// NOTIFY-FLUSH ABLAK: a connect-per-command miatt minden parancs friss
    /// connection. However PREVIOUS command's last notify frames can leak from pump
    /// buffer into NEW connection "notifications enabled -> ready"
    /// event AFTER, appearing at new command's first decode → ct.len=0B
    /// → Msg1 lost → pump repeats confirm frame until timeout
    /// ("temp basal set fails", "reservoir error"). Fix: after CCCD enable
    /// hold short QUIESCENCE window; discard incoming (leftover) notify
    /// frames, signal onReady only at window end (first write
    /// starts then). New command begins on clean notify channel.
    private var notifyFlushDeadline: Date?
    /// connect-per-command notify-flush PROFILE. Three time constants (window / idle-gap /
    /// max-window) read here for per-command-type switching:
    ///  - `.conservative`: bolus/temp/model — allows slow pump drain time (legacy 0.4/0.3/2.0s).
    ///  - `.fastReconnect`: priming fill-loop — cuts excess 2.0s max-window, BUT
    ///    does NOT take notify window below 0.5s. Pump repeats confirm frames ~390ms after StepSet;
    ///    if next (Resistance/StepSet) flush window <0.5s, stale
    ///    frames leak → bad decode/timeout/crash (seen with held-open). So
    ///    window-floor (quasi-idle minimum) = 0.5s, max-window 0.6s (≥0.5s but << 2.0s).
    ///    Motor/pressure settle NOT needed (AAPS=0ms, resistance is instantaneous).
    /// Profile set by `EquilCommandQueue.runSingleCommand` BEFORE connect.
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
        /// FILL-loop FRESH connect-per-command: cuts excess 2.0s max-window,
        /// BUT does NOT take notify window below SAFE 0.5s. After StepSet pump
        /// repeats confirm frames every ~390ms; if next (Resistance/StepSet) command
        /// flush window <0.5s, stale frames leak → bad decode/timeout/crash. GATT-cache
        /// optimization had reduced window to 0.3s — RESTORED to prior safe
        /// values: window 0.5s, max-window 0.6s. Stability is goal (~2.85s/step/command, OK).
        public static let fastReconnect = NotifyFlushProfile(window: 0.5, idleGap: 0.30, maxWindow: 0.6)
    }

    public var notifyFlushProfile: NotifyFlushProfile = .conservative

    /// Quiescence window length (from profile). Pump repeat rate and writeGap
    /// considered sufficient for leftover drain; shorter in fill-loop (fastReconnect).
    private var notifyFlushWindow: TimeInterval { notifyFlushProfile.window }
    /// true from connect until window expires. While true, ALL incoming
    /// notify frames discarded (leftover arriving BEFORE ready too).
    private var notifyFlushActive: Bool = false
    /// Token for flush window close: if NEW flush starts meanwhile, old async close
    /// doesn't fire (prevents early ready on reconnect).
    private var notifyFlushToken: UUID?
    /// IDLE-CLOSE: fixed 400ms window may expire before pump's last
    /// repeated leftover frame (~390ms repeat cycle), so it
    /// slips in AFTER ready and breaks new command's first decode (ct.len=7B
    /// → confirm frame repeats until timeout: "spinning", "no active
    /// temp"). Fix: signal ready NOT at fixed time, but WHEN notify
    /// channel actually quiesced — every incoming (discarded) leftover frame
    /// RESTARTS this idle timer. Full flush window upper bound
    /// notifyFlushMaxWindow (so silent pump doesn't hang us).
    private var notifyFlushIdleGap: TimeInterval { notifyFlushProfile.idleGap }
    /// Flush window absolute upper bound (closes even if never quiesces).
    /// Conservative profile 2.0s: after CmdModelSet (run mode, mode=1) pump drains
    /// notify buffer slower; smaller hard-deadline on max-window could close BEFORE
    /// last leftover frame arrived (→ "status cycle stuck"). FILL-loop (fastReconnect)
    /// 0.5s enough: on fresh connection idle-close + stale-filter handles leftover, so no
    /// need to wait full 2.0s every step (that was excess ~2s/step).
    private var notifyFlushMaxWindow: TimeInterval { notifyFlushProfile.maxWindow }
    /// Current flush absolute deadline (from max-window).
    private var notifyFlushHardDeadline: Date?

    /// POST-READY GRACE: after ready signal, watch briefly (one idle-gap)
    /// for leftover frame from PREVIOUS command. Status cycle stuck
    /// (after CmdModelSet) caused by stale packet ~50ms after ready,
    /// reaching onNotify and corrupting decoder context. If frame arrives during grace
    /// BEFORE new command's first write (outIndex==0), treat as leftover
    /// and discard — real command response only comes AFTER first write.
    private var notifyPostReadyGraceDeadline: Date?
    /// Post-ready grace length (one idle-gap enough for ~390ms repeat cycle's last
    /// frame filter, without delaying real response).
    private let notifyPostReadyGrace: TimeInterval = 0.30

    /// STALE-FRAME FILTER (repetition-based, independent of outIndex). Temp basal
    /// cancel→set chain: SET runs on fresh connection, but pump still repeats PREVIOUS (cancel)
    /// command notify frames EVEN AFTER SET's first write (in log
    /// 01:34:12.157–16.752, ~4.5s, same 7 frames over and over). outIndex already
    /// >0, so post-ready grace didn't filter, stale content flooded decoder →
    /// 40s timeout → yellow loop. FIX: store hex of frames SEEN during flush + grace;
    /// in post-SET grace window discard any frame already
    /// seen (= surely previous command leftover, since fresh response is encrypted and
    /// NEVER bit-identical to previous). Full stale flood can quiesce, and
    /// first previously UNSEEN (real) response reaches decoder.
    private var seenStaleFrames: Set<String> = []
    /// Stale-filter window upper bound after ready (releases even if pump
    /// never quiesces — normal cmdTimeout protects). In chain stale flood
    /// ~4.5s, so wider window needed than 0.30s grace.
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
        // Clear stale-filter state — next fresh connection starts clean.
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
        // Diagnostic listing ALWAYS runs (if wired).
        onDiscoverDiagnostic?(p, name)
        // Runner connect handler ONLY when NOT in diagnostic-only mode
        // (i.e. pairing/command running). Diagnostic scan won't connect accidentally,
        // pairing scan calls runner's original onDiscover → connect.
        if !diagnosticOnly { onDiscover?(p, name) }
    }

    public func centralManager(_: CBCentralManager, didConnect p: CBPeripheral) {
        isConnected = true
        log("connected; discovering services")
        p.delegate = self
        // NOTIFY-FLUSH WINDOW OPENS HERE: leftover notify frames (from PREVIOUS command)
        // often arrive BEFORE "ready" event (see 05.873 < 05.963 in log).
        // So start quiescence window at connect moment so everything
        // between connect and ready is discarded. ready finalized by didUpdateNotificationState
        // extends/finalizes.
        notifyFlushActive = true
        notifyFlushDeadline = Date().addingTimeInterval(notifyFlushWindow)
        notifyFlushHardDeadline = Date().addingTimeInterval(notifyFlushMaxWindow)
        // Clean grace state every fresh connection (prior cycle leftover ignored).
        notifyPostReadyGraceDeadline = nil
        // Stale-filter: on new connection seen-frame set is FRESH — during flush
        // collect discarded leftover frames here to recognize after write
        // if pump keeps repeating (temp cancel→set chain).
        seenStaleFrames.removeAll(keepingCapacity: true)
        staleFilterDeadline = nil
        // FULL, RELIABLE DISCOVERY ON EVERY RECONNECT (GATT cache reverted).
        // In connect-per-command model after FULL BLE disconnect iOS INVALIDATES
        // cached CBService/CBCharacteristic references. Prior "if already
        // discovered, skip discovery" reused dead/stale references on
        // reconnect → commands failed, connection stuck, and
        // deactivate/unpair didn't run. So EVERY reconnect runs fresh discovery
        // (discoverServices → discoverCharacteristics → setNotifyValue), as before cache.
        // Drop stale uartChar reference to use freshly discovered
        // characteristic.
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
        // AAPS connect-per-command: disconnect is NORMAL (pump ~11s inactivity
        // then drops). NO auto-reconnect — next command connects itself
        // via connectForCommand(). No watchdog↔command connection race that
        // broke bolus 2nd message (pump 10s timer starts at command begin).
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
        // NOTIFY-FLUSH: quiescence window open since connect, from here STILL
        // extend to full window so frames after notify-enable
        // are surely discarded. Signal ready only when window EXPIRES.
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
        // IDLE-CLOSE: start watching window after full window, but every
        // incoming leftover frame (didUpdateValueFor) reschedules idle timer,
        // so ready guaranteed only after channel actually quiesces.
        scheduleFlushIdleCheck(token: myToken, after: notifyFlushWindow)
    }

    /// Flush window idle-based closer. After `after` checks: if NEW flush
    /// started (token mismatch) → exit. If hard-deadline reached OR since last
    /// leftover frame idle-gap elapsed → close + ready. Otherwise reschedules.
    private func scheduleFlushIdleCheck(token: UUID, after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.notifyFlushToken == token, self.notifyFlushActive else { return }
            let now = Date()
            let hardReached = (self.notifyFlushHardDeadline.map { now >= $0 }) ?? true
            // notifyFlushDeadline advanced by every incoming leftover frame (idle-gap).
            let quietReached = (self.notifyFlushDeadline.map { now >= $0 }) ?? true
            if hardReached || quietReached {
                self.notifyFlushActive = false
                self.notifyFlushDeadline = nil
                self.notifyFlushHardDeadline = nil
                // Start POST-READY GRACE: after ready watch one more idle-gap
                // for PREVIOUS-command leftover (see notifyPostReadyGrace doc). Grace only
                // until new command's first write starts (outIndex>0).
                self.notifyPostReadyGraceDeadline = Date().addingTimeInterval(self.notifyPostReadyGrace)
                // Start stale-filter window: after ready discard repeats of frames seen during flush (= previous command)
                // after write until stale flood quiesces.
                self.staleFilterDeadline = Date().addingTimeInterval(self.staleFilterWindow)
                self
                    .log(
                        "notify-flush done (\(hardReached ? "max-window" : "idle")) -> ready (grace \(Int(self.notifyPostReadyGrace * 1000))ms, stale-filter \(Int(self.staleFilterWindow * 1000))ms)"
                    )
                self.onReady?()
            } else {
                // Not quiesced yet — recheck after next idle-gap.
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
        // Discard frames during quiescence window (previous command leftover).
        // IMPORTANT: notifyFlushActive true from connect until window expires ALWAYS,
        // so leftover before ready surely discarded (not only within deadline).
        let hex = value.hexUpper
        if notifyFlushActive {
            log("notify (flush, eldobva): \(hex)")
            // Stale-filter: remember frame seen during flush for after ready
            // if pump keeps repeating (temp cancel→set chain).
            seenStaleFrames.insert(hex)
            // IDLE-CLOSE: every discarded leftover frame advances quiescence
            // deadline so ready only after last leftover, idle-gap silence
            // (hard-deadline is upper bound).
            notifyFlushDeadline = Date().addingTimeInterval(notifyFlushIdleGap)
            return
        }
        // POST-READY GRACE: if grace not elapsed since ready AND new command's first write
        // not started (outIndex==0), this can't be real command response
        // (response always after write) → PREVIOUS command leftover, discard. So
        // stale packet after CmdModelSet doesn't corrupt decoder context.
        if outIndex == 0, let graceUntil = notifyPostReadyGraceDeadline, Date() < graceUntil {
            log("notify (post-ready grace, eldobva): \(hex)")
            seenStaleFrames.insert(hex)
            return
        }
        // STALE-FRAME FILTER (outIndex INDEPENDENT): in temp cancel→set chain pump
        // repeats previous command frames AFTER SET's first write (outIndex>0). If
        // within filter window AND exact frame seen during flush/grace,
        // surely stale (fresh encrypted response NEVER bit-identical) → discard,
        // advance filter window so full flood can quiesce.
        if let staleUntil = staleFilterDeadline, Date() < staleUntil, seenStaleFrames.contains(hex) {
            log("notify (stale-repeat, discarded): \(hex)")
            staleFilterDeadline = Date().addingTimeInterval(notifyFlushIdleGap)
            return
        }
        // First real (previously unseen) response — close filters and forward.
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

// MARK: - BT Watchdog implementation (persistent connection + force-reconnect)

//
// iOS-specific approach (stronger than AAPS connect-per-command model):
// keep paired CBPeripheral and hold/reconnect via central.connect().
// connect() runs WITHOUT timeout — iOS reconnects when pump in range,
// no new scan. Eliminates post-bond "doesn't advertise name again" scan-race,
// which caused bolus timeout.
public extension EquilBLEManager {
    /// Call after successful pairing: stores and "holds" peripheral for watchdog.
    func holdPeripheral(_ p: CBPeripheral) {
        watchdogPeripheralID = p.identifier
        peripheral = p
        p.delegate = self
        watchdogEnabled = true
        log("watchdog: peripheral fogva (\(p.name ?? "?")) id=\(p.identifier.uuidString.prefix(8))")
    }

    /// Periodic guard: if enabled and disconnected, attempts reconnect.
    func startWatchdog(intervalSeconds: Int = 3) {
        watchdogTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .seconds(intervalSeconds),
            repeating: .seconds(intervalSeconds)
        )
        timer.setEventHandler { /* watchdog kikapcsolva — AAPS connect-per-command */ }
        watchdogTimer = timer
        // Do NOT start timer: no periodic reconnect (AAPS model).
        log("watchdog: periodikus reconnect KIKAPCSOLVA (connect-per-command)")
    }

    func stopWatchdog() {
        watchdogEnabled = false
        watchdogTimer?.cancel()
        watchdogTimer = nil
        log("watchdog: stopped")
    }

    /// Immediate reconnect to held peripheral (no timeout — iOS range watch).
    func reconnectNow() {
        guard central.state == .poweredOn else {
            log("watchdog: BT nincs poweredOn (\(central.state.rawValue)) — kihagyva")
            return
        }
        guard let p = peripheral else {
            // Perhaps after app restart: try retrieve by ID.
            if let id = watchdogPeripheralID, retrieveAndHold(identifier: id) {
                log("watchdog: peripheral retrieved, reconnect…")
                if let pp = peripheral { central.connect(pp, options: nil) }
            } else {
                log("watchdog: nincs megtartott peripheral — reconnect kihagyva")
            }
            return
        }
        if isConnected { return }
        log("watchdog: reconnect attempt -> \(p.name ?? "?")")
        central.connect(p, options: [CBConnectPeripheralOptionNotifyOnConnectionKey: true])
    }

    /// After app restart: retrieve bonded peripheral without scan.
    @discardableResult func retrieveAndHold(identifier: UUID) -> Bool {
        guard let p = central.retrievePeripherals(withIdentifiers: [identifier]).first else {
            return false
        }
        holdPeripheral(p)
        return true
    }

    // MARK: - Connect-per-command (AAPS-modell)

    // Pump drops after ~11s inactivity, so do NOT hold persistent connection
    // during command. Bolus: pause watchdog → fresh connect to held peripheral
    // (no scan) → command runs → resume watchdog. No scan/reconnect race.

    /// Suspends watchdog auto-reconnect for duration of one command.
    func pauseWatchdog() {
        watchdogPaused = true
        log("watchdog: SUSPENDED (during command execution)")
    }

    /// Re-enables watchdog auto-reconnect after command.
    func resumeWatchdog() {
        guard watchdogEnabled else { return }
        watchdogPaused = false
        log("watchdog: FOLYTATVA")
    }

    /// Build fresh connection to held peripheral WITHOUT scan (AAPS connectEquil).
    /// If already connected, don't wait for onConnected — caller checks isConnected.
    /// If peripheral lost (app-restart), retrieve by ID.
    func connectForCommand() {
        guard central.state == .poweredOn else {
            log("connectForCommand: BT nincs poweredOn (\(central.state.rawValue))")
            return
        }
        // Clean start: disconnect all prior connections so pump gets fresh
        // GATT (half-open connection caused silent 10s pump disconnect).
        if let p = peripheral {
            var didCancelLive = false
            if isConnected {
                log("connectForCommand: disconnect before fresh connection")
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
            log("connectForCommand -> \(p.name ?? "?") (no scan)")
            // 500ms stack settle gap ONLY if we JUST disconnected live connection.
            // In connect-per-command fill-loop disconnect ALREADY happened (EquilCommandQueue.finish),
            // so isConnected==false → connect immediately, no extra 0.5s/step wait.
            let settle: DispatchTimeInterval = didCancelLive ? .milliseconds(500) : .milliseconds(0)
            queue.asyncAfter(deadline: .now() + settle) { [weak self] in
                guard let self, let pp = self.peripheral else { return }
                self.central.connect(pp, options: nil)
            }
        } else if let id = watchdogPeripheralID, retrieveAndHold(identifier: id) {
            log("connectForCommand: peripheral retrieved by ID")
            if let pp = peripheral {
                queue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
                    self?.central.connect(pp, options: nil)
                }
            }
        } else {
            log("connectForCommand: no held peripheral — falling back to scan")
            startScan()
        }
    }
}
