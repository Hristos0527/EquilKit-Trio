import LoopKit
import LoopKitUI
import UIKit

enum EquilUIScreen: Int, CaseIterable {
    case assemble = 0
    case pair
    case fill
    case attach
    case air
    case confirm
}

public final class EquilUICoordinator: UINavigationController, PumpManagerOnboarding, CompletionNotifying {
    private let colorPalette: LoopUIColorPalette
    private var pumpManager: EquilPumpManager?
    private var allowedInsulinTypes: [InsulinType]
    private var allowDebugFeatures: Bool
    private var fillStep = 0

    public var pumpManagerOnboardingDelegate: PumpManagerOnboardingDelegate?
    public var completionDelegate: CompletionDelegate?

    public init(
        pumpManager: EquilPumpManager? = nil,
        colorPalette: LoopUIColorPalette,
        pumpManagerSettings: PumpManagerSetupSettings? = nil,
        allowDebugFeatures: Bool,
        allowedInsulinTypes: [InsulinType] = []
    ) {
        if pumpManager == nil, pumpManagerSettings == nil {
            self.pumpManager = EquilPumpManager(state: EquilPumpState(rawValue: [:]))
        } else if pumpManager == nil, let settings = pumpManagerSettings {
            self.pumpManager = EquilPumpManager(state: EquilPumpState(settings.basalSchedule))
            self.pumpManager?.state.maxBasal = settings.maxBasalRateUnitsPerHour
            self.pumpManager?.state.maxBolus = settings.maxBolusUnits
        } else {
            self.pumpManager = pumpManager
        }

        self.colorPalette = colorPalette
        self.allowDebugFeatures = allowDebugFeatures
        self.allowedInsulinTypes = allowedInsulinTypes
        super.init(navigationBarClass: UINavigationBar.self, toolbarClass: UIToolbar.self)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        navigationBar.prefersLargeTitles = true
        let start: EquilUIScreen = pumpManager?.isOnboarded == true ? .confirm : .assemble
        setViewControllers([viewController(for: start)], animated: false)
    }

    private func viewController(for screen: EquilUIScreen) -> UIViewController {
        EquilOnboardingStepViewController(
            screen: screen,
            pumpManager: pumpManager,
            palette: colorPalette,
            fillStep: fillStep,
            onAdvance: { [weak self] in self?.advance(from: screen) },
            onPair: { [weak self] sn, pwd, completion in self?.pair(serialNumber: sn, password: pwd, completion: completion) },
            onFill: { [weak self] auto, completion in self?.fill(auto: auto, completion: completion) },
            onAir: { [weak self] completion in self?.removeAir(completion: completion) },
            onConfirm: { [weak self] completion in self?.confirm(completion: completion) }
        )
    }

    private func advance(from screen: EquilUIScreen) {
        guard let next = EquilUIScreen(rawValue: screen.rawValue + 1) else {
            finishOnboarding()
            return
        }
        pushViewController(viewController(for: next), animated: true)
    }

    private func pair(serialNumber: String, password: String, completion: @escaping (Bool, String?) -> Void) {
        guard let pumpManager else {
            completion(false, "Missing pump manager")
            return
        }
        pumpManager.state.serialNumber = serialNumber.uppercased()
        pumpManager.state.password = password.uppercased()
        pumpManager.commandQueue.serialNumber = serialNumber.uppercased()
        pumpManager.commandQueue.runPairing(
            serialNumber: serialNumber.uppercased(),
            password: password.uppercased(),
            maxBolus: pumpManager.state.maxBolus,
            maxBasal: pumpManager.state.maxBasal
        ) { result in
            if result.success {
                pumpManager.state.deviceToken = pumpManager.commandQueue.equilDevice
                pumpManager.state.password = pumpManager.commandQueue.equilPassword
                pumpManager.state.activationProgress = .priming
                pumpManager.notifyStateDidChange()
                completion(true, nil)
            } else {
                completion(false, result.errorMessage)
            }
        }
    }

    private func fill(auto: Bool, completion: @escaping (Bool, String?) -> Void) {
        guard let pumpManager else {
            completion(false, "Missing pump manager")
            return
        }
        pumpManager.commandQueue.runFill(auto: auto, startingStep: fillStep) { result in
            if result.success, result.enacted {
                self.fillStep = 0
                pumpManager.state.activationProgress = .cannulaChange
                pumpManager.notifyStateDidChange()
                completion(true, nil)
            } else if result.success {
                self.fillStep += auto ? EquilConst.EQUIL_STEP_FILL : EquilConst.EQUIL_STEP_MANUAL
                completion(true, "Continue filling")
            } else {
                completion(false, result.errorMessage)
            }
        }
    }

    private func removeAir(completion: @escaping (Bool, String?) -> Void) {
        guard let pumpManager else {
            completion(false, "Missing pump manager")
            return
        }
        pumpManager.commandQueue.runAirStep { result in
            if result.success {
                pumpManager.state.activationProgress = .cannulaInserted
                pumpManager.notifyStateDidChange()
            }
            completion(result.success, result.errorMessage)
        }
    }

    private func confirm(completion: @escaping (Bool, String?) -> Void) {
        guard let pumpManager else {
            completion(false, "Missing pump manager")
            return
        }
        var capturedInsulin: CmdInsulinGet?
        pumpManager.commandQueue.executeCmdSequence([
            {
                let cmd = CmdInsulinGet(
                    createTime: Int64(Date().timeIntervalSince1970 * 1000),
                    equilDevice: pumpManager.state.deviceToken,
                    equilPassword: pumpManager.state.password
                )
                capturedInsulin = cmd
                return cmd
            },
            {
                CmdModelSet(
                    mode: RunMode.run.rawValue,
                    createTime: Int64(Date().timeIntervalSince1970 * 1000),
                    equilDevice: pumpManager.state.deviceToken,
                    equilPassword: pumpManager.state.password
                )
            }
        ]) { result in
            guard result.success else {
                completion(false, result.errorMessage)
                return
            }
            if let insulinCmd = capturedInsulin {
                pumpManager.state.reservoir = Double(insulinCmd.insulin)
            }
            pumpManager.state.runMode = .run
            pumpManager.state.activationProgress = .completed
            pumpManager.state.isOnboarded = true
            pumpManager.state.lastSync = Date.now
            pumpManager.notifyStateDidChange()
            completion(true, nil)
            self.finishOnboarding()
        }
    }

    private func finishOnboarding() {
        guard let pumpManager else { return }
        pumpManagerOnboardingDelegate?.pumpManagerOnboarding(didCreatePumpManager: pumpManager)
        pumpManagerOnboardingDelegate?.pumpManagerOnboarding(didOnboardPumpManager: pumpManager)
        completionDelegate?.completionNotifyingDidComplete(self)
    }
}

// MARK: - Minimal step view controller

private final class EquilOnboardingStepViewController: UIViewController {
    private let screen: EquilUIScreen
    private weak var pumpManager: EquilPumpManager?
    private let palette: LoopUIColorPalette
    private let fillStep: Int
    private let onAdvance: () -> Void
    private let onPair: (String, String, @escaping (Bool, String?) -> Void) -> Void
    private let onFill: (Bool, @escaping (Bool, String?) -> Void) -> Void
    private let onAir: (@escaping (Bool, String?) -> Void) -> Void
    private let onConfirm: (@escaping (Bool, String?) -> Void) -> Void

    private let statusLabel = UILabel()
    private let serialField = UITextField()
    private let passwordField = UITextField()
    private let actionButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)

    init(
        screen: EquilUIScreen,
        pumpManager: EquilPumpManager?,
        palette: LoopUIColorPalette,
        fillStep: Int,
        onAdvance: @escaping () -> Void,
        onPair: @escaping (String, String, @escaping (Bool, String?) -> Void) -> Void,
        onFill: @escaping (Bool, @escaping (Bool, String?) -> Void) -> Void,
        onAir: @escaping (@escaping (Bool, String?) -> Void) -> Void,
        onConfirm: @escaping (@escaping (Bool, String?) -> Void) -> Void
    ) {
        self.screen = screen
        self.pumpManager = pumpManager
        self.palette = palette
        self.fillStep = fillStep
        self.onAdvance = onAdvance
        self.onPair = onPair
        self.onFill = onFill
        self.onAir = onAir
        self.onConfirm = onConfirm
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = palette.guidanceColors.background
        configureChrome()
        configureFieldsIfNeeded()
        configureButtons()
    }

    private func configureChrome() {
        switch screen {
        case .assemble:
            title = "Patch összeszerelés"
            statusLabel.text = "Szereld össze a patch-et a pump testtel az útmutató szerint."
        case .pair:
            title = "Párosítás"
            statusLabel.text = "Add meg a sorozatszámot (6 hex) és a jelszót (4 hex)."
        case .fill:
            title = "Feltöltés"
            statusLabel.text = "Töltsd fel az inzulinnal. Automatikus feltöltés a dugattyú érzékeléséig."
        case .attach:
            title = "Felhelyezés"
            statusLabel.text = "Távolítsd el a védőfóliát, és illeszd a testre."
        case .air:
            title = "Levegőztetés"
            statusLabel.text = "Távolítsd el a levegőt a kanül előtt."
        case .confirm:
            title = "Megerősítés"
            statusLabel.text = "Indítsd el a patch-et és fejezd be a beállítást."
        }

        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24)
        ])
    }

    private func configureFieldsIfNeeded() {
        guard screen == .pair else { return }
        for field in [serialField, passwordField] {
            field.borderStyle = .roundedRect
            field.autocapitalizationType = .allCharacters
            field.autocorrectionType = .no
            field.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(field)
        }
        serialField.placeholder = "Sorozatszám (6 hex)"
        passwordField.placeholder = "Jelszó (4 hex)"
        NSLayoutConstraint.activate([
            serialField.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            serialField.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            serialField.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 24),
            passwordField.leadingAnchor.constraint(equalTo: serialField.leadingAnchor),
            passwordField.trailingAnchor.constraint(equalTo: serialField.trailingAnchor),
            passwordField.topAnchor.constraint(equalTo: serialField.bottomAnchor, constant: 12)
        ])
    }

    private func configureButtons() {
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        nextButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(actionButton)
        view.addSubview(nextButton)

        switch screen {
        case .assemble,
             .attach:
            actionButton.isHidden = true
            nextButton.setTitle("Tovább", for: .normal)
            nextButton.addTarget(self, action: #selector(advanceTapped), for: .touchUpInside)
        case .pair:
            actionButton.setTitle("Párosítás", for: .normal)
            actionButton.addTarget(self, action: #selector(pairTapped), for: .touchUpInside)
            nextButton.isHidden = true
        case .fill:
            actionButton.setTitle("Automatikus feltöltés", for: .normal)
            actionButton.addTarget(self, action: #selector(fillTapped), for: .touchUpInside)
            nextButton.setTitle("Tovább", for: .normal)
            nextButton.addTarget(self, action: #selector(advanceTapped), for: .touchUpInside)
        case .air:
            actionButton.setTitle("Levegő eltávolítása", for: .normal)
            actionButton.addTarget(self, action: #selector(airTapped), for: .touchUpInside)
            nextButton.setTitle("Tovább", for: .normal)
            nextButton.addTarget(self, action: #selector(advanceTapped), for: .touchUpInside)
        case .confirm:
            actionButton.setTitle("Patch aktiválása", for: .normal)
            actionButton.addTarget(self, action: #selector(confirmTapped), for: .touchUpInside)
            nextButton.isHidden = true
        }

        NSLayoutConstraint.activate([
            actionButton.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            actionButton.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            actionButton.bottomAnchor.constraint(equalTo: nextButton.topAnchor, constant: -12),
            nextButton.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            nextButton.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            nextButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
    }

    @objc private func advanceTapped() { onAdvance() }

    @objc private func pairTapped() {
        setBusy(true)
        onPair(serialField.text ?? "", passwordField.text ?? "") { success, message in
            DispatchQueue.main.async {
                self.setBusy(false)
                self.statusLabel.text = success ? "Párosítás sikeres." : (message ?? "Párosítás sikertelen.")
                if success { self.onAdvance() }
            }
        }
    }

    @objc private func fillTapped() {
        setBusy(true)
        onFill(true) { success, message in
            DispatchQueue.main.async {
                self.setBusy(false)
                self.statusLabel.text = message ?? (success ? "Feltöltés kész." : "Feltöltés sikertelen.")
            }
        }
    }

    @objc private func airTapped() {
        setBusy(true)
        onAir { success, message in
            DispatchQueue.main.async {
                self.setBusy(false)
                self.statusLabel.text = success ? "Levegőztetés kész." : (message ?? "Hiba")
            }
        }
    }

    @objc private func confirmTapped() {
        setBusy(true)
        onConfirm { success, message in
            DispatchQueue.main.async {
                self.setBusy(false)
                self.statusLabel.text = success ? "Kész." : (message ?? "Aktiválás sikertelen.")
            }
        }
    }

    private func setBusy(_ busy: Bool) {
        actionButton.isEnabled = !busy
        nextButton.isEnabled = !busy
    }
}
