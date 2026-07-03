import Foundation
import HealthKit
import LoopKit
import os.log

enum EquilCommunicationError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(message):
            return message
        }
    }
}

public enum EquilBolusState: Int {
    case noBolus = 0
    case inProgress = 1
    case canceling = 2
}

public final class EquilPumpManager: DeviceManager {
    public static let pluginIdentifier = "Equil"
    public let localizedTitle = "Equil Patch"
    public let managerIdentifier = "Equil"

    private let log = Logger(subsystem: "org.nightscout.EquilKit", category: "EquilPumpManager")

    public let pumpDelegate = WeakSynchronizedDelegate<PumpManagerDelegate>()
    private let statusObservers = WeakSynchronizedSet<PumpManagerStatusObserver>()

    public var state: EquilPumpState
    private var oldState: EquilPumpState
    public let commandQueue: EquilCommandQueue
    private var bolusCompletionWorkItem: DispatchWorkItem?

    /// A felhasználó priming-flow-ja (Start priming után) a ViewModel/VC életciklusa felett is
    /// érvényes marad. Megakadályozza, hogy heartbeat/dashboard-sync felülírja a `pumpState`-et
    /// és az observer idő előtt elnavigáljon, miközben a fill-loop még fut.
    private let primingFlowLatchLock = NSLock()
    private var primingFlowLatched = false
    /// Throttle battery-only CmdHistoryGet when full sync is gated by `lastSync`.
    private var lastBatteryFetchAttempt = Date.distantPast

    // Background keepalive (Build #53)
    var backgroundKeepaliveTimer: DispatchSourceTimer?
    let backgroundKeepaliveQueue = DispatchQueue(label: "org.nightscout.EquilKit.backgroundKeepalive")
    var lastBackgroundKeepaliveAt = Date.distantPast
    var appIsInBackground = false

    public var rawState: PumpManager.RawStateValue { state.rawValue }

    public init(state: EquilPumpState) {
        self.state = state
        oldState = state.clone()
        commandQueue = EquilCommandQueue()
        syncCommandQueueCredentials()
        warmUpBLEPeripheralReference()
        commandQueue.onLog = { [weak self] message in
            EquilLogBuffer.shared.append(message, category: "CommandQueue", level: .info)
            self?.log.debug("\(message, privacy: .public)")
        }
        clearStaleInFlightBolus(trigger: "init")
        completeBolusIfNeeded(trigger: "init")
        setupBackgroundKeepaliveObservers()
    }

    public required convenience init?(rawState: RawStateValue) {
        self.init(state: EquilPumpState(rawValue: rawState))
    }

    public var isOnboarded: Bool { state.isOnboarded }

    public static var onboardingMaximumBasalScheduleEntryCount: Int { 48 }

    public static var onboardingSupportedBasalRates: [Double] {
        (0 ... 600).map { Double($0) / 20 }
    }

    public static var onboardingSupportedBolusVolumes: [Double] {
        (1 ... 600).map { Double($0) / 20 }
    }

    public static var onboardingSupportedMaximumBolusVolumes: [Double] {
        onboardingSupportedBolusVolumes
    }

    public var delegateQueue: DispatchQueue! {
        get { pumpDelegate.queue }
        set { pumpDelegate.queue = newValue }
    }

    public var pumpManagerDelegate: PumpManagerDelegate? {
        get { pumpDelegate.delegate }
        set { pumpDelegate.delegate = newValue }
    }

    public func roundToSupportedBolusVolume(units: Double) -> Double {
        supportedBolusVolumes.last(where: { $0 <= units }) ?? 0
    }

    public func roundToSupportedBasalRate(unitsPerHour: Double) -> Double {
        supportedBasalRates.last(where: { $0 <= unitsPerHour }) ?? 0
    }

    public var supportedBasalRates: [Double] { Self.onboardingSupportedBasalRates }
    public var supportedBolusVolumes: [Double] { Self.onboardingSupportedBolusVolumes }
    public var supportedMaximumBolusVolumes: [Double] { Self.onboardingSupportedMaximumBolusVolumes }
    public var maximumBasalScheduleEntryCount: Int { Self.onboardingMaximumBasalScheduleEntryCount }
    public var minimumBasalScheduleEntryDuration: TimeInterval { TimeInterval(minutes: 30) }

    public var debugDescription: String { state.debugDescription }

    public func acknowledgeAlert(alertIdentifier _: Alert.AlertIdentifier, completion: @escaping ((any Error)?) -> Void) {
        completion(nil)
    }

    public func getSoundBaseURL() -> URL? { nil }
    public func getSounds() -> [Alert.Sound] { [] }

    func syncCommandQueueCredentials() {
        commandQueue.equilDevice = state.deviceToken
        commandQueue.equilPassword = state.password
        commandQueue.serialNumber = state.serialNumber
        commandQueue.peripheralUUID = state.peripheralUUID
        warmUpBLEPeripheralReference()
    }

    /// Scan nélküli connectForCommand: a bondolt peripheral UUID-ját visszatöltjük app-indítás után.
    func warmUpBLEPeripheralReference() {
        guard let uuidString = state.peripheralUUID, let id = UUID(uuidString: uuidString) else { return }
        _ = commandQueue.bleManager.retrieveAndHold(identifier: id)
    }

    /// Sikeres BLE-kapcsolat után perzisztáljuk a peripheral UUID-t (scan-fallback elkerülése).
    func persistPairedPeripheralUUIDIfNeeded() {
        guard let uuid = commandQueue.bleManager.currentPeripheral?.identifier.uuidString else { return }
        guard state.peripheralUUID != uuid else { return }
        state.peripheralUUID = uuid
        commandQueue.peripheralUUID = uuid
        notifyStateDidChange()
    }

    private func device(_ state: EquilPumpState) -> HKDevice {
        HKDevice(
            name: state.pumpName,
            manufacturer: "MicroTech",
            model: state.model,
            hardwareVersion: nil,
            firmwareVersion: state.firmwareVersion.isEmpty ? nil : state.firmwareVersion,
            softwareVersion: nil,
            localIdentifier: state.serialNumber,
            udiDeviceIdentifier: nil
        )
    }

    public func notifyStateDidChange() {
        syncCommandQueueCredentials()
        DispatchQueue.main.async {
            let status = self.status
            let oldStatus = PumpManagerStatus(
                timeZone: TimeZone.current,
                device: self.device(self.oldState),
                pumpBatteryChargeRemaining: self.oldState.patchBatteryFraction,
                basalDeliveryState: self.oldState.basalDeliveryState,
                bolusState: self.oldState.bolusDose.map { .inProgress($0.toDoseEntry(isMutable: true)) } ?? .noBolus,
                insulinType: self.oldState.insulinType
            )
            self.pumpDelegate.notify { delegate in
                delegate?.pumpManagerDidUpdateState(self)
                delegate?.pumpManager(self, didUpdate: status, oldStatus: oldStatus)
            }
            self.statusObservers.forEach { observer in
                observer.pumpManager(self, didUpdate: status, oldStatus: oldStatus)
            }
            self.oldState = self.state.clone()
        }
    }

    func emitPumpEvents(_ events: [NewPumpEvent], replacePendingEvents: Bool = true) {
        pumpDelegate.notify { delegate in
            delegate?.pumpManager(
                self,
                hasNewPumpEvents: events,
                lastReconciliation: self.state.lastSync,
                replacePendingEvents: replacePendingEvents
            ) { _ in }
        }
    }

    /// Advances DoseStore recency without writing doses (handoff pumpDataTooOld fix).
    private func reportPumpDataReconciled() {
        let now = Date.now
        pumpDelegate.notify { delegate in
            delegate?.pumpManager(
                self,
                hasNewPumpEvents: [],
                lastReconciliation: now,
                replacePendingEvents: false
            ) { _ in }
        }
    }

    private func bolusState(_ bolusState: EquilBolusState) -> PumpManagerStatus.BolusState {
        switch bolusState {
        case .noBolus:
            return .noBolus
        case .canceling:
            return .canceling
        case .inProgress:
            if let dose = state.bolusDose?.toDoseEntry(isMutable: true) {
                return .inProgress(dose)
            }
            return .noBolus
        }
    }

    private var currentBolusState: EquilBolusState {
        clearExpiredBolusIfNeeded(notify: false)
        return state.bolusDose == nil ? .noBolus : .inProgress
    }

    /// Drops a persisted in-flight bolus after its estimated delivery window (crash recovery).
    private func clearExpiredBolusIfNeeded(notify: Bool) {
        guard let dose = state.bolusDose else { return }
        guard Date.now >= dose.estimatedEndDate else { return }
        state.bolusDose = nil
        if notify {
            notifyStateDidChange()
        }
    }

    /// Clears a persisted bolus that outlived its delivery window (crash / stuck queue recovery).
    private func clearStaleInFlightBolus(trigger: String) {
        guard let dose = state.bolusDose else { return }
        let staleAfter = dose.estimatedEndDate.addingTimeInterval(30)
        guard Date.now >= staleAfter else { return }
        log.warning("Clearing stale in-flight bolus (\(trigger)) started \(dose.startDate, privacy: .public)")
        EquilLogBuffer.shared.append(
            "Clearing stale in-flight bolus (\(trigger)) started \(dose.startDate)",
            category: "EquilPumpManager",
            level: .warning
        )
        bolusCompletionWorkItem?.cancel()
        bolusCompletionWorkItem = nil
        state.bolusDose = nil
        notifyStateDidChange()
    }
}

public extension EquilPumpManager {
    var pumpRecordsBasalProfileStartEvents: Bool { false }
    var pumpReservoirCapacity: Double { state.reservoirCapacity }
    var lastSync: Date? { state.lastSync }

    var status: PumpManagerStatus {
        PumpManagerStatus(
            timeZone: TimeZone.current,
            device: device(state),
            // state.battery MÁR százalék (0–100, CmdHistoryGet / sync) → 0–1 arány, NEM feszültség-képlet.
            pumpBatteryChargeRemaining: state.patchBatteryFraction,
            basalDeliveryState: state.basalDeliveryState,
            bolusState: bolusState(currentBolusState),
            insulinType: state.insulinType
        )
    }

    func ensureCurrentPumpData(completion: ((Date?) -> Void)?) {
        guard state.isOnboarded, !state.deviceToken.isEmpty else {
            completion?(nil)
            return
        }

        let fullSyncStale = Date.now.timeIntervalSince(state.lastSync) > .minutes(5)
        guard fullSyncStale else {
            // Priming/dosing frissíti a lastSync-et anélkül, hogy CmdHistoryGet lefutna —
            // ilyenkor külön húzzuk be az akkut, ne maradjon 0 a HUD-on.
            fetchHistoryBatteryIfNeeded(completion: completion)
            return
        }

        var capturedInsulin: CmdInsulinGet?
        var capturedMode: CmdRunningModeGet?
        var capturedHistory: CmdHistoryGet?

        // AKKU-KÍMÉLÉS: a CmdTimeSet NEM fut minden syncnél (az AAPS sem küldi
        // ciklusonként). Csak akkor toldjuk a sorba, ha tényleg szükséges:
        //   - még sosem állítottuk be (párosítás utáni első sync), VAGY
        //   - változott a GMT-eltolás (időzóna-/DST-váltás), VAGY
        //   - több mint 24 óra telt el az utolsó beállítás óta (lassú óradrift).
        let currentGMTOffset = TimeZone.current.secondsFromGMT(for: Date())
        let shouldSyncTime: Bool = {
            guard let lastAt = state.lastTimeSetAt else { return true }
            if state.lastTimeSetGMTOffset != currentGMTOffset { return true }
            return Date.now.timeIntervalSince(lastAt) > .hours(24)
        }()

        var sequence: [() -> EquilCommandDriving] = [
            {
                let cmd = CmdHistoryGet(
                    currentIndex: self.state.historyIndex,
                    createTime: Int64(Date().timeIntervalSince1970 * 1000),
                    equilDevice: self.state.deviceToken,
                    equilPassword: self.state.password
                )
                capturedHistory = cmd
                return cmd
            },
            {
                let cmd = CmdInsulinGet(
                    createTime: Int64(Date().timeIntervalSince1970 * 1000),
                    equilDevice: self.state.deviceToken,
                    equilPassword: self.state.password
                )
                capturedInsulin = cmd
                return cmd
            },
            {
                let cmd = CmdRunningModeGet(
                    createTime: Int64(Date().timeIntervalSince1970 * 1000),
                    equilDevice: self.state.deviceToken,
                    equilPassword: self.state.password
                )
                capturedMode = cmd
                return cmd
            }
        ]
        if shouldSyncTime {
            sequence.append {
                CmdTimeSet(
                    createTime: Int64(Date().timeIntervalSince1970 * 1000),
                    equilDevice: self.state.deviceToken,
                    equilPassword: self.state.password
                )
            }
        }

        commandQueue.executeCmdSequence(sequence) { result in
            guard result.success else {
                completion?(nil)
                return
            }
            if shouldSyncTime {
                self.state.lastTimeSetAt = Date.now
                self.state.lastTimeSetGMTOffset = currentGMTOffset
            }
            if let insulinCmd = capturedInsulin {
                self.state.reservoir = Double(insulinCmd.insulin)
            }
            if let modeCmd = capturedMode, let runMode = RunMode(rawValue: modeCmd.runMode) {
                self.state.runMode = runMode
            }
            if let historyCmd = capturedHistory {
                self.state.historyIndex = historyCmd.resultIndex
                self.state.applyHistoryBattery(historyCmd.battery)
            }
            self.completeBolusIfNeeded(trigger: "sync")
            self.state.lastSync = Date.now
            self.persistPairedPeripheralUUIDIfNeeded()
            self.notifyStateDidChange()
            self.emitReservoirLevel()
            self.reportPumpDataReconciled()
            self.refreshPumpBaseFirmwareIfNeeded {
                completion?(self.state.lastSync)
            }
        }
    }

    /// CmdHistoryGet csak az akku % miatt — nem frissíti a `lastSync`-et (ne blokkolja a 5 perces full sync gate-et).
    private func fetchHistoryBatteryIfNeeded(completion: ((Date?) -> Void)?) {
        guard state.battery == 0 else {
            completion?(nil)
            return
        }
        guard Date.now.timeIntervalSince(lastBatteryFetchAttempt) > .minutes(2) else {
            completion?(nil)
            return
        }
        lastBatteryFetchAttempt = Date.now

        var capturedHistory: CmdHistoryGet?
        commandQueue.executeCmd({
            let cmd = CmdHistoryGet(
                currentIndex: self.state.historyIndex,
                createTime: Int64(Date().timeIntervalSince1970 * 1000),
                equilDevice: self.state.deviceToken,
                equilPassword: self.state.password
            )
            capturedHistory = cmd
            return cmd
        }) { result in
            guard result.success, let historyCmd = capturedHistory else {
                completion?(nil)
                return
            }
            self.state.historyIndex = historyCmd.resultIndex
            self.state.applyHistoryBattery(historyCmd.battery)
            self.notifyStateDidChange()
            self.reportPumpDataReconciled()
            completion?(self.state.lastSync)
        }
    }

    func setMustProvideBLEHeartbeat(_: Bool) {}

    func createBolusProgressReporter(reportingOn queue: DispatchQueue) -> (any DoseProgressReporter)? {
        guard let bolusDose = state.bolusDose else { return nil }
        return EquilDoseProgressReporter(pumpManager: self, dose: bolusDose, reportingQueue: queue)
    }

    func estimatedDuration(toBolus units: Double) -> TimeInterval {
        units / 1.5 * TimeInterval(minutes: 1)
    }

    private func communicationPumpError(from result: EquilCommandQueue.CommandResult) -> PumpManagerError {
        .communication(EquilCommunicationError.commandFailed(result.errorMessage ?? "Communication failed"))
    }

    /// Loop enact előtt: teljes sync ha stale (>5 perc), majd mindig egy élő BLE ping
    /// (connect-per-command mellett a friss lastSync önmagában nem garantál elérhető pumpát).
    func prepareForLoopCycle(completion: @escaping (Bool) -> Void) {
        ensureCurrentPumpData { [weak self] _ in
            guard let self else {
                completion(false)
                return
            }
            self.pingPumpReachability(completion: completion)
        }
    }

    /// Egy CmdRunningModeGet BLE round-trip a loop előtt; executeWithRetry kezeli a connection timeout-ot.
    func pingPumpReachability(completion: @escaping (Bool) -> Void) {
        guard state.isOnboarded, !state.deviceToken.isEmpty else {
            completion(false)
            return
        }

        var capturedMode: CmdRunningModeGet?
        executeWithRetry({
            let cmd = CmdRunningModeGet(
                createTime: Int64(Date().timeIntervalSince1970 * 1000),
                equilDevice: self.state.deviceToken,
                equilPassword: self.state.password
            )
            capturedMode = cmd
            return cmd
        }) { result in
            guard result.success, let modeCmd = capturedMode, let runMode = RunMode(rawValue: modeCmd.runMode) else {
                completion(false)
                return
            }
            self.persistPairedPeripheralUUIDIfNeeded()
            self.state.runMode = runMode
            self.state.lastSync = Date.now
            self.notifyStateDidChange()
            completion(true)
        }
    }

    /// Bolus/temp/loop ping: a queue executeCmdWithRetry-je (max 3 próba, bontás+index reset backoff).
    private func executeWithRetry(
        _ makeCommand: @escaping () -> EquilCommandDriving,
        options: EquilCommandQueue.CommandOptions = .default,
        completion: @escaping (EquilCommandQueue.CommandResult) -> Void
    ) {
        commandQueue.executeCmdWithRetry(makeCommand, options: options) { [weak self] result in
            if result.success {
                self?.persistPairedPeripheralUUIDIfNeeded()
            }
            completion(result)
        }
    }

    /// A priming sikeres befejezése. RUN-mód / dosing / loop-enact CSAK ekkor engedélyezett.
    ///
    /// Párosítás után, amíg a prime nincs sikeresen lefuttatva, a pumpa NEM mehet RUN/active
    /// delivery módba (nehogy prime előtt loopoljon/adagoljon). A "prime kész" jelet két,
    /// egymást kiegészítő állapotból olvassuk ki (bármelyik elég):
    ///   - `pumpState >= .primed` (primePatch sikere ezt állítja be), VAGY
    ///   - `activationProgress` már a priming-fázison TÚL van (az onboarding fill-lépés
    ///     sikere `.cannulaChange`-re lép → a későbbi activation RUN-ja engedélyezett).
    /// Aktiváláskor (activatePatch) a pumpState ekkor már .primed, így a gate átengedi.
    var isPrimingComplete: Bool {
        state.pumpState.rawValue >= PatchState.primed.rawValue
            || state.activationProgress.rawValue > ActivationProgress.priming.rawValue
    }

    func enactBolus(
        units: Double,
        activationType: BolusActivationType,
        completion: @escaping (PumpManagerError?) -> Void
    ) {
        clearStaleInFlightBolus(trigger: "pre-enact")
        completeBolusIfNeeded(trigger: "pre-enact")
        guard state.bolusDose == nil else {
            completion(.deviceState(nil))
            return
        }

        guard state.isOnboarded, !state.deviceToken.isEmpty else {
            completion(.configuration(nil))
            return
        }

        // RUN-mód GATE: prime sikere ELŐTT semmilyen dosing nem mehet (a wakePort RUN-t küldene).
        guard isPrimingComplete else {
            log.warning("enactBolus blokkolva: a priming még nincs befejezve (RUN-mód tiltva)")
            EquilLogBuffer.shared.append(
                "enactBolus blokkolva: a priming még nincs befejezve (RUN-mód tiltva)",
                category: "EquilPumpManager",
                level: .warning
            )
            completion(.deviceState(nil))
            return
        }

        guard units > 0 else {
            completion(.configuration(nil))
            return
        }

        // Manual suspend must not auto-resume (handoff + Trio verifyStatus both block suspended dosing).
        if state.isSuspended {
            completion(.deviceState(nil))
            return
        }

        let startDate = Date.now
        let duration = estimatedDuration(toBolus: units)
        let doseEntry = UnfinalizedDose(
            units: units,
            duration: duration,
            activationType: activationType,
            insulinType: state.insulinType
        )

        wakePort0404ForDosing { [weak self] in
            guard let self else {
                completion(.communication(EquilCommunicationError.commandFailed("Pump manager deallocated")))
                return
            }
            self.executeWithRetry({
                CmdLargeBasalSet(
                    insulin: units,
                    createTime: Int64(Date().timeIntervalSince1970 * 1000),
                    equilDevice: self.state.deviceToken,
                    equilPassword: self.state.password
                )
            }) { result in
                guard result.success else {
                    self.bolusCompletionWorkItem?.cancel()
                    self.bolusCompletionWorkItem = nil
                    self.state.bolusDose = nil
                    self.notifyStateDidChange()
                    completion(self.communicationPumpError(from: result))
                    return
                }

                self.state.bolusDose = doseEntry
                self.state.runMode = .run
                self.emitPumpEvents([NewPumpEvent.bolus(unfinalizedDose: doseEntry)])
                self.state.lastSync = Date.now
                self.notifyStateDidChange()
                self.scheduleBolusCompletion(for: doseEntry)
                completion(nil)

                self.reconcileHistory(triggeredBy: "bolus", withReservoir: true) {
                    self.state.lastSync = Date.now
                    self.notifyStateDidChange()
                }
            }
        }
    }

    func cancelBolus(completion: @escaping (PumpManagerResult<DoseEntry?>) -> Void) {
        let programmedUnits = state.bolusDose?.value
        let bolusStartDate = state.bolusDose?.startDate
        let reservoirBefore = state.reservoir

        let cmd = CmdLargeBasalSet(
            insulin: 0,
            createTime: Int64(Date().timeIntervalSince1970 * 1000),
            equilDevice: state.deviceToken,
            equilPassword: state.password
        )

        commandQueue.preemptAndExecute({ cmd }) { result in
            guard result.success else {
                completion(.failure(.communication(nil)))
                return
            }
            self.reconcileHistory(triggeredBy: "bolus stop", withReservoir: true) {
                if let programmed = programmedUnits, let start = bolusStartDate {
                    let elapsed = max(0, Date().timeIntervalSince(start))
                    let fullDuration = max(self.estimatedDuration(toBolus: programmed), 0.001)
                    let timeFraction = min(1.0, elapsed / fullDuration)
                    var deliveredEstimate = (programmed * timeFraction).rounded(toPlaces: 2)
                    if reservoirBefore >= self.state.reservoir {
                        let delta = reservoirBefore - self.state.reservoir
                        if delta >= 1, delta <= programmed { deliveredEstimate = delta }
                    }
                    let corrected = DoseEntry(
                        type: .bolus,
                        startDate: start,
                        endDate: Date(),
                        value: programmed,
                        unit: .units,
                        deliveredUnits: deliveredEstimate,
                        insulinType: self.state.insulinType
                    )
                    self.emitPumpEvents([
                        NewPumpEvent.bolus(dose: corrected, units: programmed, date: start)
                    ], replacePendingEvents: true)
                }
                self.state.bolusDose = nil
                self.bolusCompletionWorkItem?.cancel()
                self.bolusCompletionWorkItem = nil
                self.state.lastSync = Date.now
                self.notifyStateDidChange()
                completion(.success(nil))
            }
        }
    }

    func enactTempBasal(
        unitsPerHour: Double,
        for duration: TimeInterval,
        completion: @escaping (PumpManagerError?) -> Void
    ) {
        let durationMinutes = max(0, Int(duration / 60))

        // RUN-mód GATE: prime sikere ELŐTT a temp basal (és a benne lévő RUN/wake) tiltott.
        guard isPrimingComplete else {
            log.warning("enactTempBasal blokkolva: a priming még nincs befejezve (RUN-mód tiltva)")
            EquilLogBuffer.shared.append(
                "enactTempBasal blokkolva: a priming még nincs befejezve (RUN-mód tiltva)",
                category: "EquilPumpManager",
                level: .warning
            )
            completion(.deviceState(nil))
            return
        }

        if state.isSuspended && unitsPerHour > 0 && durationMinutes > 0 {
            resumeDelivery { error in
                if let error {
                    completion(.communication(error as? LocalizedError))
                    return
                }
                self.enactTempBasal(unitsPerHour: unitsPerHour, for: duration, completion: completion)
            }
            return
        }

        // Handoff fix: 0 U/hr → physical suspend (CmdModelSet mode=0) but report temp-0 to Loop,
        // NOT suspend — avoids frozen yellow loop state.
        if unitsPerHour <= 0 || durationMinutes <= 0 {
            executeWithRetry({
                CmdModelSet(
                    mode: RunMode.suspend.rawValue,
                    createTime: Int64(Date().timeIntervalSince1970 * 1000),
                    equilDevice: self.state.deviceToken,
                    equilPassword: self.state.password
                )
            }, options: EquilCommandQueue.CommandOptions(zeroValueAck: true)) { result in
                guard result.success else {
                    completion(self.communicationPumpError(from: result))
                    return
                }
                let tempBasalDose = UnfinalizedDose(
                    tempRate: 0,
                    duration: duration,
                    insulinType: self.state.insulinType
                )
                self.emitPumpEvents([
                    NewPumpEvent.tempBasal(
                        dose: tempBasalDose.toDoseEntry(isMutable: true),
                        date: tempBasalDose.startDate
                    )
                ])
                self.state.basalDose = tempBasalDose
                self.state.runMode = .suspend
                self.state.lastSync = Date.now
                self.notifyStateDidChange()
                // Átmeneti MUTE: zero-temp (fizikai suspend) alatt a patch ne rezegjen/villogjon.
                self.applyTransientMuteForSuspend()
                completion(nil)
            }
            return
        }

        let cancelCmd = {
            CmdTempBasalSet(
                insulin: 0,
                duration: 0,
                createTime: Int64(Date().timeIntervalSince1970 * 1000),
                equilDevice: self.state.deviceToken,
                equilPassword: self.state.password
            )
        }
        let setCmd = {
            CmdTempBasalSet(
                insulin: unitsPerHour,
                duration: durationMinutes,
                createTime: Int64(Date().timeIntervalSince1970 * 1000),
                equilDevice: self.state.deviceToken,
                equilPassword: self.state.password
            )
        }

        wakePort0404ForDosing { [weak self] in
            guard let self else {
                completion(.communication(EquilCommunicationError.commandFailed("Pump manager deallocated")))
                return
            }
            self.executeWithRetry(
                cancelCmd,
                options: EquilCommandQueue.CommandOptions(zeroValueAck: true)
            ) { cancelResult in
                guard cancelResult.success else {
                    completion(self.communicationPumpError(from: cancelResult))
                    return
                }
                self.executeWithRetry({ setCmd() }) { setResult in
                    guard setResult.success else {
                        completion(self.communicationPumpError(from: setResult))
                        return
                    }

                    let tempBasalDose = UnfinalizedDose(
                        tempRate: unitsPerHour,
                        duration: duration,
                        insulinType: self.state.insulinType
                    )
                    self.emitPumpEvents([
                        NewPumpEvent.tempBasal(
                            dose: tempBasalDose.toDoseEntry(isMutable: true),
                            date: tempBasalDose.startDate
                        )
                    ])
                    self.state.basalDose = tempBasalDose
                    self.state.runMode = .run
                    self.state.lastSync = Date.now
                    self.notifyStateDidChange()
                    // RUN-ba visszatérés: az átmeneti MUTE előtti alarm-mód visszaállítása.
                    self.restoreAlarmModeAfterResume()
                    // AKKU-KÍMÉLÉS: a temp basal után NEM húzunk be külön historyt — a
                    // következő `ensureCurrentPumpData` sync úgyis behozza (CmdHistoryGet).
                    // A temp basal dose-event már kiment fent (emitPumpEvents), így az IOB
                    // azonnal frissül; csak a redundáns extra BLE-olvasást spóroljuk meg.
                    completion(nil)
                }
            }
        }
    }

    func enactExtendedBolus(units: Double, durationMinutes: Int, completion: @escaping (PumpManagerError?) -> Void) {
        let cmd = CmdExtendedBolusSet(
            insulin: units,
            durationInMinutes: durationMinutes,
            cancel: false,
            createTime: Int64(Date().timeIntervalSince1970 * 1000),
            equilDevice: state.deviceToken,
            equilPassword: state.password
        )

        commandQueue.executeCmd({ cmd }) { result in
            guard result.success else {
                completion(.communication(nil))
                return
            }
            self.state.lastSync = Date.now
            self.notifyStateDidChange()
            completion(nil)
        }
    }

    func suspendDelivery(completion: @escaping ((any Error)?) -> Void) {
        commandQueue.suspendDelivery { result in
            guard result.success else {
                completion(NSError(
                    domain: "EquilKit",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: result.errorMessage ?? "Suspend failed"]
                ))
                return
            }
            let start = Date.now
            let basalDose = UnfinalizedDose(suspendStartTime: start)
            self.emitPumpEvents([NewPumpEvent.suspend(dose: basalDose.toDoseEntry())])
            self.state.basalDose = basalDose
            self.state.isSuspended = true
            self.state.runMode = .suspend
            self.state.lastSync = Date.now
            self.notifyStateDidChange()
            // Átmeneti MUTE: suspend alatt a patch ne rezegjen/villogjon.
            self.applyTransientMuteForSuspend()
            completion(nil)
        }
    }

    func resumeDelivery(completion: @escaping ((any Error)?) -> Void) {
        // RUN-mód GATE: prime sikere ELŐTT a resume (CmdModelSet RUN) nem engedélyezett.
        guard isPrimingComplete else {
            log.warning("resumeDelivery blokkolva: a priming még nincs befejezve (RUN-mód tiltva)")
            EquilLogBuffer.shared.append(
                "resumeDelivery blokkolva: a priming még nincs befejezve (RUN-mód tiltva)",
                category: "EquilPumpManager",
                level: .warning
            )
            completion(NSError(
                domain: "EquilKit",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Priming not complete — RUN mode disabled"]
            ))
            return
        }
        commandQueue.resumeDelivery { result in
            guard result.success else {
                completion(NSError(
                    domain: "EquilKit",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: result.errorMessage ?? "Resume failed"]
                ))
                return
            }
            let resumeDose = UnfinalizedDose(resumeStartTime: Date.now, insulinType: self.state.insulinType)
            self.emitPumpEvents([NewPumpEvent.resume(dose: resumeDose.toDoseEntry(), date: resumeDose.startDate)])
            self.state.basalDose = resumeDose
            self.state.isSuspended = false
            self.state.runMode = .run
            self.state.lastSync = Date.now
            self.notifyStateDidChange()
            // RUN-ba visszatérés: az átmeneti MUTE előtti alarm-mód visszaállítása.
            self.restoreAlarmModeAfterResume()
            completion(nil)
        }
    }

    func syncBasalRateSchedule(
        items: [RepeatingScheduleValue<Double>],
        completion: @escaping (Result<BasalRateSchedule, any Error>) -> Void
    ) {
        guard let basalSchedule = DailyValueSchedule<Double>(dailyItems: items) else {
            completion(.failure(NSError(
                domain: "EquilKit",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Empty basal schedule"]
            )))
            return
        }

        let equilSchedule = EquilPumpState.makeBasalSchedule(from: items)
        let cmd = CmdBasalSet(
            basalSchedule: equilSchedule,
            createTime: Int64(Date().timeIntervalSince1970 * 1000),
            equilDevice: state.deviceToken,
            equilPassword: state.password
        )

        commandQueue.executeCmd({ cmd }) { result in
            guard result.success else {
                completion(.failure(NSError(
                    domain: "EquilKit",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: result.errorMessage ?? "Basal sync failed"]
                )))
                return
            }
            self.state.basalSchedule = equilSchedule
            self.state.lastSync = Date.now
            self.notifyStateDidChange()
            completion(.success(basalSchedule))
        }
    }

    func syncDeliveryLimits(
        limits: DeliveryLimits,
        completion: @escaping (Result<DeliveryLimits, any Error>) -> Void
    ) {
        completion(.success(limits))
    }

    func addStatusObserver(_ observer: PumpManagerStatusObserver, queue: DispatchQueue) {
        statusObservers.insert(observer, queue: queue)
    }

    func removeStatusObserver(_ observer: PumpManagerStatusObserver) {
        statusObservers.removeElement(observer)
    }

    func emitReservoirLevel() {
        pumpDelegate.notify { delegate in
            delegate?.pumpManager(
                self,
                didReadReservoirValue: self.state.reservoir,
                at: self.state.lastSync
            ) { _ in }
        }
    }

    // MARK: - Átmeneti MUTE suspend / zero-temp idejére (resume-nál visszaállítás)

    /// Suspend / zero-temp BE-lépéskor: elmenti az aktuális alarm-módot, majd MUTE-ra vált,
    /// hogy a patch ne rezegjen/villogjon a leállás alatt. CSAK ÁTMENETNÉL fut: ha már mute,
    /// vagy már van mentett érték (verseny-védelem), NEM küld újra parancsot — így nem minden
    /// loop ciklusban megy mute.
    private func applyTransientMuteForSuspend() {
        guard !state.deviceToken.isEmpty else { return }
        // Már van mentés (átmeneti mute aktív) → ne írjuk felül, ne küldjünk újra.
        guard state.savedAlarmModeBeforeSuspend == nil else { return }
        // A user PERZISZTENS módja már Silent (mute) → nincs mit elnémítani, és NINCS mentés:
        // így a resume-nál SOHA nem próbálunk visszaállítani semmit → marad Silent (nem vált Soundra).
        guard state.alarmModeRaw != AlarmMode.mute.rawValue else { return }

        // A user perzisztens beállítását (alarmModeRaw) jegyezzük fel — de a mute-ot
        // `persist: false`-szal küldjük, így az alarmModeRaw NEM íródik felül. Resume-nál
        // alapértelmezetten Silent marad; csak `userExplicitAlarmMode` esetén áll vissza a mentett mód.
        state.savedAlarmModeBeforeSuspend = state.alarmModeRaw
        notifyStateDidChange()
        setAlarmMode(.mute, persist: false) { [weak self] result in
            guard let self else { return }
            if case .failure = result {
                // Sikertelen mute → a mentést visszavonjuk, hogy a következő átmenet újrapróbálja.
                self.state.savedAlarmModeBeforeSuspend = nil
                self.notifyStateDidChange()
            }
        }
    }

    /// Resume / pozitív-temp (RUN-ba visszatérés) esetén: alapértelmezetten Silent marad
    /// (a patch már mute-on van az átmeneti mute miatt). Csak dashboard-ról explicit választott
    /// nem-néma módot állítjuk vissza — a gyári `.tone` default SOHA nem kerül vissza.
    private func restoreAlarmModeAfterResume() {
        guard let savedMode = state.savedAlarmModeBeforeSuspend else { return }
        state.savedAlarmModeBeforeSuspend = nil
        notifyStateDidChange()
        guard !state.deviceToken.isEmpty else { return }

        if state.userExplicitAlarmMode, savedMode != AlarmMode.mute.rawValue {
            setAlarmMode(AlarmMode.fromInt(savedMode), persist: false) { _ in }
            return
        }

        // Alapértelmezés: Silent — a patch már mute-on van, csak a lokális állapotot igazítjuk.
        if state.alarmModeRaw != AlarmMode.mute.rawValue {
            state.alarmModeRaw = AlarmMode.mute.rawValue
            notifyStateDidChange()
        }
    }

    // MARK: - Handoff manager layer (same Cmd* to pump; Trio-facing bookkeeping)

    func wakePort0404ForDosing(then proceed: @escaping () -> Void) {
        guard state.isOnboarded, !state.deviceToken.isEmpty else {
            proceed()
            return
        }
        // RUN-mód GATE: prime sikere ELŐTT SOHA ne küldjünk RUN-t (védelem; a dosing
        // belépőket már a fenti guardok blokkolják, de a wake önállóan is biztosított).
        guard isPrimingComplete else {
            log.warning("wakePort0404ForDosing: RUN kihagyva — a priming még nincs befejezve")
            EquilLogBuffer.shared.append(
                "wakePort0404ForDosing: RUN kihagyva — a priming még nincs befejezve",
                category: "EquilPumpManager",
                level: .warning
            )
            proceed()
            return
        }
        // Never send RUN while manually suspended — would undo suspendDelivery.
        guard !state.isSuspended else {
            proceed()
            return
        }
        // AKKU-KÍMÉLÉS: ha BIZTOSAN RUN módban vagyunk, ne küldjünk felesleges
        // CmdModelSet(RUN)-t (a sync `CmdRunningModeGet`-ből frissíti a runMode-ot).
        // Bármi más (.none/.suspend/.stop/bizonytalan) esetén KÜLDJÜK, hogy a dózis
        // ne maradjon el — biztonság elöl.
        guard state.runMode != .run else {
            proceed()
            return
        }
        let wake = CmdModelSet(
            mode: RunMode.run.rawValue,
            createTime: Int64(Date().timeIntervalSince1970 * 1000),
            equilDevice: state.deviceToken,
            equilPassword: state.password
        )
        commandQueue.executeCmd({ wake }) { _ in
            proceed()
        }
    }

    func scheduleBolusCompletion(for dose: UnfinalizedDose) {
        bolusCompletionWorkItem?.cancel()
        let delay = max(0.5, dose.estimatedEndDate.timeIntervalSinceNow + 0.5)
        let workItem = DispatchWorkItem { [weak self] in
            self?.completeBolusIfNeeded(trigger: "timer")
        }
        bolusCompletionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Finalize in-flight bolus so Loop can accept the next dose (Medtrum-style completion path).
    func completeBolusIfNeeded(trigger: String) {
        guard let dose = state.bolusDose else { return }
        guard Date.now >= dose.estimatedEndDate else { return }

        bolusCompletionWorkItem?.cancel()
        bolusCompletionWorkItem = nil

        let programmed = dose.value
        dose.deliveredUnits = programmed
        let finalized = dose.toDoseEntry(useEstimatedEndDate: true)
        emitPumpEvents([
            NewPumpEvent.bolus(dose: finalized, units: programmed, date: dose.startDate)
        ], replacePendingEvents: true)
        state.bolusDose = nil
        state.lastSync = Date.now
        notifyStateDidChange()
        reconcileHistory(triggeredBy: "bolus complete (\(trigger))", withReservoir: true) {}
    }

    func reconcileHistory(
        triggeredBy reason: String,
        withReservoir: Bool = false,
        then: @escaping () -> Void
    ) {
        var historyCmd: CmdHistoryGet?
        commandQueue.executeCmd({
            let cmd = CmdHistoryGet(
                currentIndex: 0,
                createTime: Int64(Date().timeIntervalSince1970 * 1000),
                equilDevice: self.state.deviceToken,
                equilPassword: self.state.password
            )
            historyCmd = cmd
            return cmd
        }) { result in
            guard result.success, let cmd = historyCmd else {
                then()
                return
            }
            self.state.historyIndex = cmd.resultIndex
            self.state.applyHistoryBattery(cmd.battery)
            self.notifyStateDidChange()
            if withReservoir {
                self.fetchReservoir(reason: reason, then: then)
            } else {
                self.reportPumpDataReconciled()
                then()
            }
        }
    }

    private func fetchReservoir(reason _: String, then: @escaping () -> Void) {
        var insulinCmd: CmdInsulinGet?
        commandQueue.executeCmd({
            let cmd = CmdInsulinGet(
                createTime: Int64(Date().timeIntervalSince1970 * 1000),
                equilDevice: self.state.deviceToken,
                equilPassword: self.state.password
            )
            insulinCmd = cmd
            return cmd
        }) { result in
            if result.success, let cmd = insulinCmd, cmd.insulin >= 0 {
                self.state.reservoir = Double(cmd.insulin)
                self.emitReservoirLevel()
            }
            self.reportPumpDataReconciled()
            then()
        }
    }

    /// Igaz, amíg a priming fill-loop ténylegesen FUT (a queue szálbiztos flagje). A priming
    /// képernyő ezt nézi, hogy a háttérben futó loop közben NE navigáljon el (egy köztes
    /// dashboard-sync státusz-frissítésre sem) — csak siker/cancel navigál.
    public var isPrimingActive: Bool { commandQueue.isPrimingFillActive }

    /// Igaz, amíg a felhasználó a priming képernyőn van és elindította (vagy folytatja) a flow-t.
    /// A latch a pumpManager szintjén él — túléli a VC/ViewModel újraépítést is.
    public var isPrimingFlowLatched: Bool {
        primingFlowLatchLock.lock()
        defer { primingFlowLatchLock.unlock() }
        return primingFlowLatched
    }

    func latchPrimingFlow() {
        primingFlowLatchLock.lock()
        primingFlowLatched = true
        primingFlowLatchLock.unlock()
    }

    func unlatchPrimingFlow() {
        primingFlowLatchLock.lock()
        primingFlowLatched = false
        primingFlowLatchLock.unlock()
    }

    func primePatch(_ completion: @escaping (EquilPrimePatchResult) -> Void) {
        guard !state.deviceToken.isEmpty else {
            completion(.failure(error: .noKnownPumpBase))
            return
        }
        latchPrimingFlow()
        state.pumpState = .priming
        // runFill ELŐBB: szinkron fillLoopActivePublished=true, mielőtt notifyStateDidChange
        // observer-t indítana (különben finishPrimingIfReady idő előtt navigál).
        commandQueue.runFill(auto: true) { result in
            guard result.success else {
                completion(.failure(error: .connectionFailure(reason: result.errorMessage ?? "Prime failed")))
                return
            }
            if result.enacted {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self.state.pumpState = .primed
                    if self.state.activationProgress.rawValue <= ActivationProgress.priming.rawValue {
                        self.state.activationProgress = .cannulaChange
                    }
                    self.state.primeProgress = 240
                    self.state.lastSync = Date.now
                    self.notifyStateDidChange()
                    completion(.success)
                }
            } else {
                self.state.primeProgress = min(self.state.primeProgress + 10, 239)
                self.notifyStateDidChange()
                completion(.success)
            }
        }
        notifyStateDidChange()
    }

    /// PRIMING STOP/CANCEL: a felhasználó leállítja a (esetleg elakadt) priming-loopot. A queue
    /// fill-loopját tisztán leállítja, a futó parancsot megszakítja és a kapcsolatot bontja, hogy
    /// az új parancsok (Delete Pump / deactivate / unpair) AZONNAL átmenjenek. A priming-állapotot
    /// visszaállítja `filled`-re, hogy a UI ne ragadjon „Priming"-ben (újra-prime vagy törlés mehet).
    func cancelPriming() {
        commandQueue.cancelPriming()
        if state.pumpState == .priming {
            state.pumpState = .filled
            state.primeProgress = 0
            notifyStateDidChange()
        }
    }

    /// One-shot pump base firmware read for Patch Details when pairing did not persist it.
    func refreshPumpBaseFirmwareIfNeeded(then: @escaping () -> Void = {}) {
        guard state.swVersion.isEmpty,
              state.firmwareVersion.isEmpty,
              !state.deviceToken.isEmpty
        else {
            then()
            return
        }

        var devicesCmd: CmdDevicesGet?
        commandQueue.executeCmd({
            let cmd = CmdDevicesGet(
                createTime: Int64(Date().timeIntervalSince1970 * 1000),
                equilDevice: self.state.deviceToken,
                equilPassword: self.state.password
            )
            devicesCmd = cmd
            return cmd
        }) { [weak self] result in
            guard let self else {
                then()
                return
            }
            if result.success, let firmware = devicesCmd?.firmwareVersion, !firmware.isEmpty {
                self.applyPumpBaseFirmware(firmware)
            }
            then()
        }
    }

    private func applyPumpBaseFirmware(_ firmware: String) {
        state.firmwareVersion = firmware
        if state.swVersion.isEmpty {
            state.swVersion = firmware
        }
        notifyStateDidChange()
    }
}
