import HealthKit
import LoopKit
import LoopKitUI
import SwiftUI
import UIKit

enum PatchLifecycleState {
    case noPatch
    case active
    case activeLast24h
    case gracePeriod
    case expired
    case expiredBasalOnly
}

class EquilKitSettingsViewModel: PatchLifetimeFormatting, ObservableObject, PumpManagerStatusObserver {
    private let processQueue = DispatchQueue(label: "com.nightscout.medtrumkit.settingsViewModel")

    @Published var model: String = ""
    @Published var is300u: Bool = false
    @Published var showPumpTimeSyncWarning = false
    @Published var reservoirLevel: Double = 0
    @Published var maxReservoirLevel: Double = 1
    @Published var pumpTime = Date.distantPast
    @Published var pumpTimeSyncedAt = Date.distantPast
    @Published var patchState: PatchState = .none
    @Published var patchStateString: String = PatchState.none.description
    @Published var basalType: DoseType = .basal
    @Published var basalRate: Double = 0
    @Published var insulinType: InsulinType = .novolog
    @Published var lastSync = Date.distantPast
    @Published var hourlyLimit = 0
    @Published var dailyLimit = 0
    @Published var patchLifecycleProgress: Double = 0
    @Published var patchLifecycleState: PatchLifecycleState = .noPatch
    @Published var patchLifetime: String = ""
    @Published var patchActivatedAt: Date? = nil
    @Published var patchExpiresAt: Date? = nil
    @Published var patchGracePeriodFrom: Date? = nil
    @Published var patchGraceTimeout = ""
    @Published var isConnected: Bool = false
    @Published var isReconnecting: Bool = false
    @Published var isUpdatingAlarmMode = false
    @Published var alarmMode: AlarmMode = .tone
    @Published var isUpdatingPumpState = false
    @Published var isUpdatingSuspend = false
    @Published var isUpdatingTempBasal = false
    @Published var showManualTempBasal = false
    @Published var isPrimingOneStep = false
    @Published var oneStepPrimeMessage = ""
    @Published var oneStepPrimeSucceeded = false
    @Published var isRetractingPlunger = false
    @Published var retractPlungerError = ""
    @Published var showingRetractPlungerConfirmation = false
    @Published var showingHeartbeatWarning = false
    @Published var showingDeleteConfirmation = false
    @Published var showingSuspendPicker = false
    @Published var hasPreviousPatch = false
    @Published var isClearingAlert = false
    @Published var battery: Double = 0
    @Published var equilLogPreview: String = ""
    @Published var equilLogCopied = false

    public var pumpName: String {
        pumpManager?.state.pumpName ?? "Equil Nano"
    }

    let reservoirVolumeFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.roundingMode = .floor
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    let basalRateFormatter: NumberFormatter = {
        let numberFormatter = NumberFormatter()
        numberFormatter.numberStyle = .decimal
        numberFormatter.minimumFractionDigits = 1
        numberFormatter.minimumIntegerDigits = 1
        return numberFormatter
    }()

    let dateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter
    }()

    let dateTimeFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    let timeRemainingFormatter: DateComponentsFormatter = {
        let dateComponentsFormatter = DateComponentsFormatter()
        dateComponentsFormatter.allowedUnits = [.hour, .minute]
        dateComponentsFormatter.unitsStyle = .full
        dateComponentsFormatter.zeroFormattingBehavior = .dropAll
        return dateComponentsFormatter
    }()

    let deactivatePatchAction: () -> Void
    let pumpRemovalAction: () -> Void
    let toSettings: () -> Void
    let toPatchDetails: () -> Void
    let toPreviousPatchDetails: () -> Void
    let toInsulinType: () -> Void
    let pumpActivationAction: (Bool) -> Void
    let activatePatchAction: () -> Void
    let toFullPriming: () -> Void
    var didFinish: (() -> Void)?
    private let log = EquilLogger(category: "settingsViewModel")
    private let pumpManager: EquilPumpManager?
    /// Patch logic: pump is "in range" if BLE is live or last successful comms was recent.
    private let recentCommsWindow: TimeInterval = 15 * 60
    init(
        _ pumpManager: EquilPumpManager?,
        _ deactivatePatchAction: @escaping () -> Void,
        _ pumpActivationAction: @escaping (Bool) -> Void,
        _ toSettings: @escaping () -> Void,
        _ toPatchDetails: @escaping () -> Void,
        _ toPreviousPatchDetails: @escaping () -> Void,
        _ toInsulinType: @escaping () -> Void,
        _ pumpRemovalAction: @escaping () -> Void,
        _ activatePatchAction: @escaping () -> Void,
        _ toFullPriming: @escaping () -> Void
    ) {
        self.pumpManager = pumpManager
        self.deactivatePatchAction = deactivatePatchAction
        self.pumpActivationAction = pumpActivationAction
        self.pumpRemovalAction = pumpRemovalAction
        self.toInsulinType = toInsulinType
        self.toPatchDetails = toPatchDetails
        self.toPreviousPatchDetails = toPreviousPatchDetails
        self.toSettings = toSettings
        self.activatePatchAction = activatePatchAction
        self.toFullPriming = toFullPriming
        super.init()

        guard let pumpManager = pumpManager else {
            return
        }

        isConnected = connectionInRange(for: pumpManager)
        alarmMode = pumpManager.alarmMode
        updateState(pumpManager.state)
        pumpManager.addStatusObserver(self, queue: processQueue)
    }

    deinit {
        pumpManager?.removeStatusObserver(self)
    }

    func reservoirText(for units: Double) -> String {
        reservoirVolumeFormatter.string(from: units as NSNumber) ?? ""
    }

    func batteryText(for percent: Double) -> String {
        EquilPumpState.displayBatteryText(for: percent)
    }

    var patchLifecycleDays: Int? {
        guard patchLifecycleState == .active || patchLifecycleState == .activeLast24h, let patchGracePeriodFrom else {
            return nil
        }

        return Int((patchGracePeriodFrom.timeIntervalSince1970 - Date.now.timeIntervalSince1970).days.rounded(.towardZero))
    }

    var patchLifecycleHours: Int? {
        guard patchLifecycleState == .active || patchLifecycleState == .activeLast24h, let patchGracePeriodFrom else {
            return nil
        }

        return Int(
            (patchGracePeriodFrom.timeIntervalSince1970 - Date.now.timeIntervalSince1970).hours
                .truncatingRemainder(dividingBy: 24).rounded(.towardZero)
        )
    }

    var patchLifecycleMinutes: Int? {
        guard patchLifecycleState == .active || patchLifecycleState == .activeLast24h, let patchGracePeriodFrom else {
            return nil
        }

        return Int(
            (patchGracePeriodFrom.timeIntervalSince1970 - Date.now.timeIntervalSince1970).minutes
                .truncatingRemainder(dividingBy: 60).rounded(.towardZero)
        )
    }

    func syncData() {
        guard let pumpManager = self.pumpManager else {
            return
        }

        isUpdatingPumpState = true
        pumpManager.syncPumpData { _ in
            DispatchQueue.main.async {
                self.isUpdatingPumpState = false
                if let pumpManager = self.pumpManager {
                    self.isConnected = self.connectionInRange(for: pumpManager)
                }
            }
        }
    }

    func clearAlert(_ alertType: AlertType) {
        guard let pumpManager else {
            return
        }

        isClearingAlert = true
        pumpManager.clearAlert(alertType: alertType) { _ in
            DispatchQueue.main.async {
                self.isClearingAlert = false
            }
        }
    }

    func didChangeInsulinType(_ newType: InsulinType?) {
        guard let type = newType else {
            return
        }

        pumpManager?.state.insulinType = type
        pumpManager?.notifyStateDidChange()
        insulinType = type
    }

    func stopUsingEquil() {
        deletePumpWithSafeSequence()
    }

    /// Pump removal REQUIRED sequence: 1) Retract Plunger → 2) Stop → 3) Unpair/forget.
    /// Pump-side retract+stop (and state clear + BLE disconnect) completes successfully (or
    /// error handling) BEFORE Trio-side removal (pumpRemovalAction).
    func deletePumpWithSafeSequence() {
        guard let pumpManager = self.pumpManager else {
            pumpRemovalAction()
            return
        }

        isRetractingPlunger = true
        retractPlungerError = ""
        pumpManager.unpairPatchWithSafeSequence { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRetractingPlunger = false
                if let error {
                    self.log.error("Unpair sequence error (continuing with removal): \(error)")
                }
                // 3) Unpair/forget: delegate notification + Trio-side removal.
                pumpManager.notifyDelegateOfDeactivation {
                    DispatchQueue.main.async {
                        self.pumpRemovalAction()
                    }
                }
            }
        }
    }

    func getLogs() -> [URL] {
        if let pumpManager = self.pumpManager {
            log.info(pumpManager.state.debugDescription)
        }
        return log.getDebugLogs()
    }

    func refreshEquilLogPreview() {
        equilLogPreview = EquilLogBuffer.shared.previewText(lineCount: 20)
    }

    func copyEquilLogToClipboard() {
        UIPasteboard.general.string = EquilLogBuffer.shared.exportText()
        equilLogCopied = true
        refreshEquilLogPreview()
    }

    func clearEquilLog() {
        EquilLogBuffer.shared.clear()
        equilLogCopied = false
        refreshEquilLogPreview()
    }

    func toPumpActivation() {
        guard let pumpManager = self.pumpManager else {
            pumpActivationAction(false)
            return
        }

        let alreadyPrimed = pumpManager.state.pumpState.rawValue >= PatchState.primed.rawValue
        pumpActivationAction(alreadyPrimed)
    }

    func suspendDelivery(duration: TimeInterval) {
        guard let pumpManager else {
            return
        }

        isUpdatingSuspend = true
        pumpManager.suspendPatch(duration: duration) { error in
            DispatchQueue.main.async {
                self.isUpdatingSuspend = false
            }

            if let error = error {
                self.log.error("Failed to suspend delivery: \(error)")
            }
        }
    }

    func suspendResumeButtonPressed() {
        if basalType != .suspend {
            showingSuspendPicker = true
            return
        }

        guard let pumpManager = self.pumpManager else {
            return
        }

        isUpdatingSuspend = true
        pumpManager.resumeDelivery { error in
            DispatchQueue.main.async {
                self.isUpdatingSuspend = false
            }

            if let error = error {
                self.log.error("Failed to resume delivery: \(error)")
            }
        }
    }

    func stopTempBasal() {
        guard let pumpManager = self.pumpManager else {
            return
        }

        isUpdatingTempBasal = true
        pumpManager.enactTempBasal(unitsPerHour: 0, for: 0) { error in
            DispatchQueue.main.async {
                self.isUpdatingTempBasal = false
            }

            if let error = error {
                self.log.error("Failed to stop temp basal: \(error)")
            }
        }
    }

    static let supportedTempBasalDurations: [TimeInterval] = (1 ... 48).map { Double($0) * .minutes(30) }

    var allowedTempBasalRates: [Double] {
        guard let pumpManager else { return [] }
        return pumpManager.supportedBasalRates.filter { $0 > 0 && $0 <= pumpManager.state.maxBasal }
    }

    func enactTempBasal(unitsPerHour: Double, duration: TimeInterval, completion: @escaping (PumpManagerError?) -> Void) {
        guard let pumpManager else {
            completion(.communication(nil))
            return
        }

        isUpdatingTempBasal = true
        pumpManager.enactTempBasal(unitsPerHour: unitsPerHour, for: duration) { error in
            DispatchQueue.main.async {
                self.isUpdatingTempBasal = false
            }
            completion(error)
        }
    }

    func primeOneStep() {
        guard let pumpManager else { return }

        isPrimingOneStep = true
        oneStepPrimeMessage = ""
        oneStepPrimeSucceeded = false
        pumpManager.primeOneStep { result in
            DispatchQueue.main.async {
                self.isPrimingOneStep = false
                switch result {
                case .success:
                    self.oneStepPrimeSucceeded = true
                    self.oneStepPrimeMessage = String(
                        localized: "Prime step completed. Repeat if needed.",
                        comment: "Success message after one-step prime"
                    )
                case let .failure(error):
                    self.oneStepPrimeSucceeded = false
                    self.oneStepPrimeMessage = error.localizedDescription
                }
            }
        }
    }

    func retractPlungerForReservoirChange() {
        guard let pumpManager else { return }

        isRetractingPlunger = true
        retractPlungerError = ""
        pumpManager.retractPlungerForReservoirChange { error in
            DispatchQueue.main.async {
                self.isRetractingPlunger = false
                if let error {
                    self.retractPlungerError = error.localizedDescription
                }
            }
        }
    }

    func checkConnection() {
        guard let pumpManager = self.pumpManager else {
            return
        }

        if connectionInRange(for: pumpManager) {
            pumpManager.bluetooth.disconnect(force: true)
            return
        }

        isReconnecting = true
        pumpManager.syncPumpData { _ in
            DispatchQueue.main.async {
                self.isReconnecting = false
                if let pumpManager = self.pumpManager {
                    self.isConnected = self.connectionInRange(for: pumpManager)
                }
            }
        }
    }

    func setAlarmMode(_ mode: AlarmMode) {
        guard let pumpManager else { return }

        isUpdatingAlarmMode = true
        pumpManager.setAlarmMode(mode) { result in
            DispatchQueue.main.async {
                self.isUpdatingAlarmMode = false
                if case .success = result {
                    self.alarmMode = mode
                }
            }
        }
    }

    func syncPumpTime() {
        guard let pumpManager else {
            return
        }

        isUpdatingPumpState = true
        pumpManager.syncPumpTime { [weak self] in
            DispatchQueue.main.async {
                self?.isUpdatingPumpState = false
            }
        }
    }
}

extension EquilKitSettingsViewModel {
    func pumpManager(
        _ pumpManager: any LoopKit.PumpManager,
        didUpdate _: LoopKit.PumpManagerStatus,
        oldStatus _: LoopKit.PumpManagerStatus
    ) {
        guard let pumpManager = pumpManager as? EquilPumpManager else {
            return
        }

        DispatchQueue.main.async {
            self.isConnected = self.connectionInRange(for: pumpManager)
            self.updateState(pumpManager.state)
        }
    }

    private func connectionInRange(for pumpManager: EquilPumpManager) -> Bool {
        if pumpManager.bluetooth.isConnected {
            return true
        }
        let lastSync = pumpManager.state.lastSync
        guard lastSync != Date.distantPast else {
            return false
        }
        return Date.now.timeIntervalSince(lastSync) < recentCommsWindow
    }

    private func updateState(_ state: EquilPumpState) {
        alarmMode = AlarmMode.fromInt(state.alarmModeRaw)
        model = state.model
        switch model {
        case "MD8301":
            is300u = true
            maxReservoirLevel = 300
        default:
            if let initial = state.initialReservoir, initial > 250 {
                is300u = true
                maxReservoirLevel = 300
            } else {
                is300u = state.pumpName.contains("300U")
                maxReservoirLevel = is300u ? 300 : 200
            }
        }

        showPumpTimeSyncWarning = state.shouldShowTimeWarning()
        patchState = state.pumpState
        patchStateString = state.pumpState.description
        pumpTime = state.pumpTime
        pumpTimeSyncedAt = state.pumpTimeSyncedAt
        reservoirLevel = patchState != .reservoirEmpty ? state.reservoir : 0
        battery = state.battery
        updateBasalDisplay(from: state)
        lastSync = state.lastSync
        patchActivatedAt = state.patchActivatedAt
        patchGracePeriodFrom = state.patchGracePeriodFrom
        patchExpiresAt = state.patchExpiresAt
        if let patchActivatedAt = state.patchActivatedAt {
            patchLifetime = processPatchLifetime(patchActivatedAt, Date())
        }
        hasPreviousPatch = state.previousPatch != nil
        hourlyLimit = Int(state.maxHourlyInsulin)
        dailyLimit = Int(state.maxDailyInsulin)

        if let pumpManager {
            isConnected = connectionInRange(for: pumpManager)
        }

        if !state.patchId.isEmpty, let patchActivatedAt, let patchGracePeriodFrom {
            let totalLifetime = patchGracePeriodFrom.timeIntervalSince(patchActivatedAt)
            let progress = Date.now.timeIntervalSince1970 - patchActivatedAt.timeIntervalSince1970

            if totalLifetime > 0 {
                patchLifecycleProgress = min(progress / totalLifetime, 1)
            } else {
                patchLifecycleProgress = 1
            }
            patchLifecycleState = getLifecycleState(state: state)

            if patchLifecycleState == .gracePeriod, let patchExpiresAt {
                let timeRemaining = patchExpiresAt.timeIntervalSinceNow
                patchGraceTimeout = timeRemainingFormatter.string(from: timeRemaining) ?? ""
            }
        } else {
            patchLifecycleState = .noPatch
        }

        if let insulinType = state.insulinType {
            self.insulinType = insulinType
        }
    }

    /// Dashboard basal: dose events (.resume) carry value 0 — show schedule rate instead.
    private func updateBasalDisplay(from state: EquilPumpState) {
        if state.isSuspended || state.basalDose.type == .suspend {
            basalType = .suspend
            basalRate = 0
        } else if state.basalDose.type == .tempBasal {
            basalType = .tempBasal
            basalRate = state.basalDose.value
        } else {
            basalType = .basal
            basalRate = state.currentBaseBasalRate
        }
    }

    private func getLifecycleState(state: EquilPumpState) -> PatchLifecycleState {
        if patchLifecycleProgress < 1 {
            if let patchGracePeriodFrom = state.patchGracePeriodFrom,
               patchGracePeriodFrom.addingTimeInterval(.days(-1)) <= Date.now
            {
                return .activeLast24h
            } else {
                return .active
            }
        }

        if let patchExpiresAt, Date.now > patchExpiresAt {
            return state.expiryMode == .extended ? .expiredBasalOnly : .expired
        }

        return .gracePeriod
    }
}
