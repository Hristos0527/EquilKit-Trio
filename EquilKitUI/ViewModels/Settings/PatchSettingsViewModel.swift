import LoopKit

class PatchSettingsViewModel: ObservableObject {
    @Published var maxHourlyInsulin: Double = 0 {
        didSet { checkDirtyState() }
    }

    @Published var maxDailyInsulin: Double = 0 {
        didSet { checkDirtyState() }
    }

    @Published var expirationTimer: Double = 1 {
        didSet { checkDirtyState() }
    }

    @Published var notificationAfterActivation: Double = 70 {
        didSet { checkDirtyState() }
    }

    @Published var lowReservoirNotification: Double = 0 {
        didSet { checkDirtyState() }
    }

    @Published var lowBatteryNotification: Double = 0 {
        didSet { checkDirtyState() }
    }

    @Published var isDirty: Bool = false
    @Published var is300u: Bool = false
    @Published var isUpdating = false
    @Published var noActivePatch = false
    @Published var errorMessage: String = ""

    var allowedOptionsDaily: [Double] = []
    var allowedOptionsHourly: [Double] = []

    let updatePatch: Bool
    let nextStep: (() -> Void)?

    private let processQueue = DispatchQueue(label: "com.nightscout.equilkit.patchSettingsViewModel")
    private let pumpManager: EquilPumpManager?
    init(_ pumpManager: EquilPumpManager?, updatePatch: Bool, nextStep: (() -> Void)?) {
        self.pumpManager = pumpManager
        self.updatePatch = updatePatch
        self.nextStep = nextStep

        guard let pumpManager = pumpManager else {
            return
        }

        updateState(pumpManager.state)
        pumpManager.addStatusObserver(self, queue: processQueue)
    }

    deinit {
        pumpManager?.removeStatusObserver(self)
    }

    func save() {
        guard let pumpManager = pumpManager else {
            return
        }

        if !updatePatch || noActivePatch {
            updateState(pumpManager: pumpManager)
            nextStep?()
            return
        }

        AuthorizeBiometrics.authenticate { success in
            guard success else {
                DispatchQueue.main.async {
                    self.errorMessage = String(localized: "Authentication failure", comment: "auth failed")
                }
                return
            }

            DispatchQueue.main.async {
                self.updateState(pumpManager: pumpManager)
                self.isUpdating = true
            }

            pumpManager.updatePatchSettings { result in
                DispatchQueue.main.async {
                    self.isUpdating = false
                    switch result {
                    case let .failure(error):
                        self.errorMessage = error.localizedDescription
                        return
                    case .success:
                        self.nextStep?()
                        return
                    }
                }
            }
        }
    }

    func checkDirtyState() {
        guard let pumpManager = pumpManager else {
            return
        }

        DispatchQueue.main.async {
            self.isDirty = (
                pumpManager.state.maxDailyInsulin != self.maxDailyInsulin ||
                    pumpManager.state.maxHourlyInsulin != self.maxHourlyInsulin ||
                    Double(pumpManager.state.expiryMode.timer) != self.expirationTimer ||
                    pumpManager.state.notificationAfterActivation.hours != self.notificationAfterActivation ||
                    (pumpManager.state.lowReservoirWarning ?? 0) != self.lowReservoirNotification ||
                    (pumpManager.state.lowBatteryWarning ?? 0) != self.lowBatteryNotification
            )
        }
    }

    private func updateState(pumpManager: EquilPumpManager) {
        pumpManager.state.maxHourlyInsulin = maxHourlyInsulin
        pumpManager.state.maxDailyInsulin = maxDailyInsulin
        pumpManager.state.expiryMode = expirationTimer == 1 ? .default : .extended
        pumpManager.state.notificationAfterActivation = .hours(notificationAfterActivation)

        if lowReservoirNotification == 0 {
            pumpManager.state.lowReservoirWarning = nil
        } else {
            pumpManager.state.lowReservoirWarning = lowReservoirNotification
        }

        if lowBatteryNotification == 0 {
            pumpManager.state.lowBatteryWarning = nil
        } else {
            pumpManager.state.lowBatteryWarning = lowBatteryNotification
        }

        pumpManager.notifyStateDidChange()

        NotificationManager.activatePatchExpiredNotification(after: .hours(notificationAfterActivation))
    }
}

extension PatchSettingsViewModel: PumpManagerStatusObserver {
    func pumpManager(
        _ pumpManager: any LoopKit.PumpManager,
        didUpdate _: LoopKit.PumpManagerStatus,
        oldStatus _: LoopKit.PumpManagerStatus
    ) {
        guard let pumpManager = pumpManager as? EquilPumpManager else {
            return
        }

        updateState(pumpManager.state)
    }

    func updateState(_ state: EquilPumpState) {
        DispatchQueue.main.async {
            self.noActivePatch = state.patchId.isEmpty
            self.maxHourlyInsulin = state.maxHourlyInsulin
            self.maxDailyInsulin = state.maxDailyInsulin
            self.expirationTimer = Double(state.expiryMode.timer)
            self.notificationAfterActivation = state.notificationAfterActivation.hours
            self.lowReservoirNotification = state.lowReservoirWarning ?? 0
            self.lowBatteryNotification = state.lowBatteryWarning ?? 0

            if state.pumpSN.isEmpty {
                self.is300u = false
                self.allowedOptionsDaily = Array(1 ... 36).map({ Double($0) * 5 })
                self.allowedOptionsHourly = [1, 2, 5, 10, 15, 20, 25, 30, 35, 40]

            } else {
                self.is300u = state.pumpName.contains("300U")

                if self.is300u {
                    self.allowedOptionsDaily = Array(1 ... 54).map({ Double($0) * 5 })
                    self.allowedOptionsHourly = [1, 2, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60]

                } else {
                    self.allowedOptionsDaily = Array(1 ... 36).map({ Double($0) * 5 })
                    self.allowedOptionsHourly = [1, 2, 5, 10, 15, 20, 25, 30, 35, 40]
                }
            }
        }
    }
}
