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

    /// User priming flow (after Start priming) remains valid beyond ViewModel/VC lifecycle.
    /// Prevents heartbeat/dashboard-sync from overwriting `pumpState`
    /// and observer navigating away early while fill-loop still runs.
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

    /// Scan-less connectForCommand: reload bonded peripheral UUID after app launch.
    func warmUpBLEPeripheralReference() {
        guard let uuidString = state.peripheralUUID, let id = UUID(uuidString: uuidString) else { return }
        _ = commandQueue.bleManager.retrieveAndHold(identifier: id)
    }

    /// After successful BLE connection persist peripheral UUID (avoid scan fallback).
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
            // state.battery is ALREADY percent (0–100, CmdHistoryGet / sync) → 0–1 fraction, NOT voltage formula.
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
            // Priming/dosing updates lastSync without CmdHistoryGet —
            // fetch battery separately so HUD doesn't stay at 0.
            fetchHistoryBatteryIfNeeded(completion: completion)
            return
        }

        var capturedInsulin: CmdInsulinGet?
        var capturedMode: CmdRunningModeGet?
        var capturedHistory: CmdHistoryGet?

        // BATTERY SAVING: CmdTimeSet does NOT run every sync (AAPS doesn't either
        // each cycle). Only queue when actually needed:
        //   - never set yet (first sync after pairing), OR
        //   - GMT offset changed (timezone/DST change), OR
        //   - more than 24 hours since last set (slow clock drift).
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

    /// CmdHistoryGet for battery % only — does not update `lastSync` (don't block 5-minute full sync gate).
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

    /// Before loop enact: full sync if stale (>5 min), then always live BLE ping
    /// (with connect-per-command fresh lastSync alone doesn't guarantee reachable pump).
    func prepareForLoopCycle(completion: @escaping (Bool) -> Void) {
        ensureCurrentPumpData { [weak self] _ in
            guard let self else {
                completion(false)
                return
            }
            self.pingPumpReachability(completion: completion)
        }
    }

    /// One CmdRunningModeGet BLE round-trip before loop; executeWithRetry handles connection timeout.
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

    /// Bolus/temp/loop ping: queue executeCmdWithRetry (max 3 attempts, disconnect+index reset backoff).
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

    /// Successful priming completion. RUN mode / dosing / loop-enact ONLY allowed then.
    ///
    /// After pairing, until prime succeeds, pump must NOT enter RUN/active
    /// delivery mode (avoid looping/dosing before prime). "prime complete" signal from two
    /// complementary states (either suffices):
    ///   - `pumpState >= .primed` (primePatch success sets this), OR
    ///   - `activationProgress` past priming phase (onboarding fill step
    ///     success advances to `.cannulaChange` → later activation RUN allowed).
    /// On activation (activatePatch) pumpState is already .primed, so gate allows.
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

        // RUN mode GATE: no dosing before prime success (wakePort would send RUN).
        guard isPrimingComplete else {
            log.warning("enactBolus blocked: priming not complete (RUN mode disabled)")
            EquilLogBuffer.shared.append(
                "enactBolus blocked: priming not complete (RUN mode disabled)",
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

        // RUN mode GATE: temp basal (and its RUN/wake) blocked before prime success.
        guard isPrimingComplete else {
            log.warning("enactTempBasal blocked: priming not complete (RUN mode disabled)")
            EquilLogBuffer.shared.append(
                "enactTempBasal blocked: priming not complete (RUN mode disabled)",
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
                // Temporary MUTE: during zero-temp (physical suspend) patch should not vibrate/beep.
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
                    // Return to RUN: restore alarm mode before temporary MUTE.
                    self.restoreAlarmModeAfterResume()
                    // BATTERY SAVING: after temp basal do NOT fetch separate history —
                    // next `ensureCurrentPumpData` sync brings it (CmdHistoryGet).
                    // Temp basal dose-event already emitted (emitPumpEvents), so IOB
                    // updates immediately; only skip redundant extra BLE read.
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
            // Temporary MUTE: during suspend patch should not vibrate/beep.
            self.applyTransientMuteForSuspend()
            completion(nil)
        }
    }

    func resumeDelivery(completion: @escaping ((any Error)?) -> Void) {
        // RUN mode GATE: resume (CmdModelSet RUN) not allowed before prime success.
        guard isPrimingComplete else {
            log.warning("resumeDelivery blocked: priming not complete (RUN mode disabled)")
            EquilLogBuffer.shared.append(
                "resumeDelivery blocked: priming not complete (RUN mode disabled)",
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
            // Return to RUN: restore alarm mode before temporary MUTE.
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

    // MARK: - Temporary MUTE during suspend / zero-temp (restore on resume)

    /// On suspend / zero-temp entry: save current alarm mode, then switch to MUTE
    /// so patch doesn't vibrate/beep while stopped. ONLY for transitions: if already mute,
    /// or saved value exists (race guard), do NOT resend — so not every
    /// loop cycle sends mute.
    private func applyTransientMuteForSuspend() {
        guard !state.deviceToken.isEmpty else { return }
        // Save already exists (temporary mute active) → don't overwrite, don't resend.
        guard state.savedAlarmModeBeforeSuspend == nil else { return }
        // User PERSISTENT mode already Silent (mute) → nothing to mute, NO save:
        // so on resume NEVER restore anything → stays Silent (won't switch to Sound).
        guard state.alarmModeRaw != AlarmMode.mute.rawValue else { return }

        // Record user persistent setting (alarmModeRaw) — but send mute
        // with `persist: false`, so alarmModeRaw is NOT overwritten. On resume
        // Silent by default; only restore saved mode with `userExplicitAlarmMode`.
        state.savedAlarmModeBeforeSuspend = state.alarmModeRaw
        notifyStateDidChange()
        setAlarmMode(.mute, persist: false) { [weak self] result in
            guard let self else { return }
            if case .failure = result {
                // Failed mute → undo save so next transition retries.
                self.state.savedAlarmModeBeforeSuspend = nil
                self.notifyStateDidChange()
            }
        }
    }

    /// On resume / positive-temp (return to RUN): Silent by default
    /// (patch already muted from temporary mute). Only restore explicitly chosen
    /// non-silent mode from dashboard — factory `.tone` default NEVER restored.
    private func restoreAlarmModeAfterResume() {
        guard let savedMode = state.savedAlarmModeBeforeSuspend else { return }
        state.savedAlarmModeBeforeSuspend = nil
        notifyStateDidChange()
        guard !state.deviceToken.isEmpty else { return }

        if state.userExplicitAlarmMode, savedMode != AlarmMode.mute.rawValue {
            setAlarmMode(AlarmMode.fromInt(savedMode), persist: false) { _ in }
            return
        }

        // Default: Silent — patch already muted, only align local state.
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
        // RUN mode GATE: NEVER send RUN before prime success (guard; dosing
        // entry points blocked above, but wake independently guarded).
        guard isPrimingComplete else {
            log.warning("wakePort0404ForDosing: RUN skipped — priming not complete")
            EquilLogBuffer.shared.append(
                "wakePort0404ForDosing: RUN skipped — priming not complete",
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
        // BATTERY SAVING: if DEFINITELY in RUN mode, don't send unnecessary
        // CmdModelSet(RUN) (sync updates runMode from `CmdRunningModeGet`).
        // Anything else (.none/.suspend/.stop/uncertain) SEND RUN so dose
        // isn't missed — safety first.
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

    /// true while priming fill-loop actually RUNS (queue thread-safe flag). Priming
    /// screen checks this so background loop does NOT navigate away (even on intermediate
    /// dashboard-sync status update) — only success/cancel navigates.
    public var isPrimingActive: Bool { commandQueue.isPrimingFillActive }

    /// true while user is on priming screen and started (or continues) the flow.
    /// Latch lives at pumpManager level — survives VC/ViewModel rebuild.
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
        // runFill FIRST: sync fillLoopActivePublished=true before notifyStateDidChange
        // would start observer (otherwise finishPrimingIfReady navigates early).
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

    /// PRIMING STOP/CANCEL: user stops (possibly stuck) priming loop. Queue
    /// cleanly stops fill-loop, aborts running command and disconnects so
    /// new commands (Delete Pump / deactivate / unpair) proceed IMMEDIATELY. Priming state
    /// reset to `filled` so UI doesn't stick on "Priming" (re-prime or delete allowed).
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
