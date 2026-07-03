class PumpBaseSettingsViewModel: ObservableObject {
    @Published var isOnboarded = false
    @Published var is300u = false
    @Published var serialNumber: String = ""
    @Published var errorMessage: String = ""

    private let logger = EquilLogger(category: "PumpBaseSettingsViewModel")
    private let pumpManager: EquilPumpManager?
    private let nextStep: () -> Void
    init(
        _ pumpManager: EquilPumpManager?,
        _ nextStep: @escaping () -> Void
    ) {
        self.pumpManager = pumpManager
        self.nextStep = nextStep

        guard let pumpManager = pumpManager else {
            return
        }

        isOnboarded = pumpManager.state.isOnboarded
        serialNumber = pumpManager.state.serialNumber.uppercased()
        if !pumpManager.state.serialNumber.isEmpty {
            is300u = pumpManager.state.pumpName.contains("300U")
        }
    }

    func saveAndContinue() {
        let normalized = serialNumber.uppercased()
        guard normalized.count == 6 else {
            logger.error("Serial Number is too short: \(serialNumber)")
            errorMessage = "Serial number must be 6 hex characters"
            return
        }

        guard normalized.range(of: "^[0-9A-F]{6}$", options: .regularExpression) != nil else {
            logger.error("Serial Number is invalid hex format: \(serialNumber)")
            errorMessage = "Serial number must be 6 hex characters"
            return
        }

        guard let pumpManager = pumpManager else {
            logger.error("No pump manager available")
            errorMessage = "No pump manager available"
            return
        }

        let currentSN = pumpManager.state.serialNumber.uppercased()
        if !currentSN.isEmpty, currentSN != normalized {
            logger.info("Serial number change detected -> Removing references to old pump base...")
            pumpManager.bluetooth.clearPeripheral()
            // PUMPACSERE: SN-váltáskor a régi pumpa credentials-ét is töröljük, hogy ÚJ párosítás
            // KELLJEN (ne maradjon új-SN + régi-token). A priming-gate is reseteljen.
            pumpManager.state.deviceToken = ""
            pumpManager.state.password = ""
            pumpManager.state.pairingPassword = ""
            pumpManager.state.pumpState = .none
            pumpManager.state.primeProgress = 0
            pumpManager.state.activationProgress = .none
            pumpManager.state.peripheralUUID = nil
            pumpManager.state.patchId = Data()
            pumpManager.state.sessionToken = Data()
        }

        pumpManager.state.serialNumber = normalized
        pumpManager.state.pumpSN = Data(normalized.utf8)

        errorMessage = ""

        pumpManager.state.isOnboarded = true
        pumpManager.notifyStateDidChange()
        nextStep()
    }
}
