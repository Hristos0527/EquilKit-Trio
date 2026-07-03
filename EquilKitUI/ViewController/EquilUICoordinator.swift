import LoopKit
import LoopKitUI
import SwiftUI
import UIKit

enum EquilUIScreen {
    case welcomeScreen
    case insulinTypeScreen
    case patchSettingsScreen
    case pairingScreen
    case deactivatePatchScreen
    case pumpBaseSettingsScreen
    case patchPrimingScreen
    case patchActivationScreen
    case settingsScreen
    case patchDetailsScreen
    case patchPreviousDetailsScreen
}

public final class EquilUICoordinator: UINavigationController, PumpManagerOnboarding, CompletionNotifying {
    private let colorPalette: LoopUIColorPalette
    private var pumpManager: EquilPumpManager?
    private var allowedInsulinTypes: [InsulinType]
    private var allowDebugFeatures: Bool
    private let opensSettingsDashboard: Bool
    private var primingFromDashboard = false

    var screenStack = [EquilUIScreen]()

    public var pumpManagerOnboardingDelegate: PumpManagerOnboardingDelegate?
    public var completionDelegate: CompletionDelegate?

    public init(
        pumpManager: EquilPumpManager? = nil,
        colorPalette: LoopUIColorPalette,
        pumpManagerSettings: PumpManagerSetupSettings? = nil,
        allowDebugFeatures: Bool,
        allowedInsulinTypes: [InsulinType] = [],
        opensSettingsDashboard: Bool = false
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
        self.opensSettingsDashboard = opensSettingsDashboard
        super.init(navigationBarClass: UINavigationBar.self, toolbarClass: UIToolbar.self)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        navigationBar.prefersLargeTitles = true
        pumpManager?.state.normalizeDashboardStateIfNeeded()

        if screenStack.isEmpty {
            screenStack = getInitialScreens()
            let viewControllers = screenStack.map {
                let viewController = viewControllerForScreen($0)
                viewController.isModalInPresentation = false
                return viewController
            }
            setViewControllers(viewControllers, animated: false)
        }
    }

    func getInitialScreens() -> [EquilUIScreen] {
        if opensSettingsDashboard {
            return [.settingsScreen]
        }

        guard let pumpManager else {
            return [.settingsScreen]
        }

        if pumpManager.state.deviceToken.isEmpty {
            if !pumpManager.isOnboarded {
                return [.welcomeScreen]
            }
            return [.settingsScreen, .pairingScreen]
        }

        if !pumpManager.isOnboarded {
            return [.welcomeScreen]
        }

        if pumpManager.state.pumpState.rawValue < PatchState.priming.rawValue {
            return [.settingsScreen, .patchPrimingScreen]
        }

        if pumpManager.state.pumpState.rawValue < PatchState.primed.rawValue {
            return [.patchPrimingScreen]
        }

        if pumpManager.state.pumpState.rawValue < PatchState.active.rawValue {
            return [.patchActivationScreen]
        }

        return [.settingsScreen]
    }

    private func viewControllerForScreen(_ screen: EquilUIScreen) -> UIViewController {
        switch screen {
        case .welcomeScreen:
            return hostingController(rootView: OnboardingWelcomeView(nextStep: { self.navigateTo(.insulinTypeScreen) }))

        case .insulinTypeScreen:
            let nextStep: (InsulinType) -> Void = { insulinType in
                self.pumpManager?.state.insulinType = insulinType
                self.pumpManager?.notifyStateDidChange()

                if let pumpManager = self.pumpManager, pumpManager.isOnboarded {
                    return
                }

                self.navigateTo(.patchSettingsScreen)
            }
            return hostingController(rootView: InsulinTypeSelector(
                initialValue: pumpManager?.state.insulinType ?? allowedInsulinTypes.first ?? .novolog,
                supportedInsulinTypes: allowedInsulinTypes
                    .isEmpty ? [.novolog, .humalog, .apidra, .fiasp, .lyumjev] : allowedInsulinTypes,
                showSave: pumpManager?.isOnboarded ?? false,
                didConfirm: nextStep
            ))

        case .patchSettingsScreen:
            let nextStep = {
                if let pumpManager = self.pumpManager, pumpManager.isOnboarded {
                    return
                }
                if self.pumpManager?.state.deviceToken.isEmpty == true {
                    self.navigateTo(.pairingScreen)
                } else {
                    self.navigateTo(.patchPrimingScreen)
                }
            }
            let viewModel = PatchSettingsViewModel(
                pumpManager,
                updatePatch: pumpManager?.isOnboarded ?? false,
                nextStep: nextStep
            )
            var dirtyCheck = false
            if let pumpManager {
                dirtyCheck = !pumpManager.state.patchId.isEmpty
            }
            return hostingController(rootView: PatchSettingsView(viewModel: viewModel, doDirtyCheck: dirtyCheck))

        case .pairingScreen:
            return pairingViewController()

        case .deactivatePatchScreen:
            let nextStep = { self.resetNavigationTo([.settingsScreen, .patchPrimingScreen]) }
            let viewModel = DeactivatePatchViewModel(pumpManager, nextStep)
            return hostingController(rootView: PatchDeactivationView(viewModel: viewModel))

        case .pumpBaseSettingsScreen:
            let nextStep = {
                if let pumpManager = self.pumpManager {
                    pumpManager.state.isOnboarded = true
                    pumpManager.notifyStateDidChange()
                    self.pumpManagerOnboardingDelegate?.pumpManagerOnboarding(didCreatePumpManager: pumpManager)
                }
                self.navigateTo(.patchPrimingScreen)
            }
            let viewModel = PumpBaseSettingsViewModel(pumpManager, nextStep)
            return hostingController(rootView: PumpBaseSettingsView(viewModel: viewModel))

        case .patchPrimingScreen:
            let viewModel = PatchPrimingViewModel(
                pumpManager,
                {
                    self.pumpManager?.unlatchPrimingFlow()
                    self.resetNavigationTo([.patchActivationScreen])
                },
                {
                    self.pumpManager?.unlatchPrimingFlow()
                    if self.pumpManager?.state.deviceToken.isEmpty == true {
                        self.navigateTo(.pairingScreen)
                    } else {
                        self.navigateTo(.pumpBaseSettingsScreen)
                    }
                },
                {
                    self.pumpManager?.unlatchPrimingFlow()
                    self.resetNavigationTo([.settingsScreen])
                },
                fromDashboard: primingFromDashboard
            )
            return hostingController(
                rootView: PatchPrimingView(viewModel: viewModel)
                    .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            )

        case .patchActivationScreen:
            let viewModel = PatchActivationViewModel(
                pumpManager,
                {
                    self.resetNavigationTo([.settingsScreen])
                    if self.isOnboardingFlow {
                        self.finishOnboarding()
                    }
                },
                { self.navigateTo(.patchPrimingScreen) }
            )
            return hostingController(
                rootView: PatchActivationView(viewModel: viewModel)
                    .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            )

        case .settingsScreen:
            let viewModel = EquilKitSettingsViewModel(
                pumpManager,
                { self.navigateTo(.deactivatePatchScreen) },
                { alreadyPrimed in
                    self.navigateTo(alreadyPrimed ? .patchActivationScreen : .patchPrimingScreen)
                },
                { self.navigateTo(.patchSettingsScreen) },
                { self.navigateTo(.patchDetailsScreen) },
                { self.navigateTo(.patchPreviousDetailsScreen) },
                { self.navigateTo(.insulinTypeScreen) },
                { self.pumpRemoval() },
                {
                    if self.pumpManager?.state.deviceToken.isEmpty == true {
                        self.navigateTo(.pairingScreen)
                    } else {
                        self.navigateTo(.patchPrimingScreen)
                    }
                },
                {
                    self.primingFromDashboard = true
                    self.resetNavigationTo([.settingsScreen, .patchPrimingScreen])
                }
            )
            viewModel.didFinish = { [weak self] in
                guard let self else { return }
                completionDelegate?.completionNotifyingDidComplete(self)
            }
            return hostingController(rootView: EquilKitSettings(viewModel: viewModel))

        case .patchDetailsScreen:
            let viewModel = PatchDetailsViewModel(pumpManager: pumpManager)
            return hostingController(rootView: PatchDetailsView(viewModel: viewModel))

        case .patchPreviousDetailsScreen:
            let viewModel = PreviousPatchDetailsViewModel(pumpManager: pumpManager)
            return hostingController(rootView: PreviousPatchDetailsView(viewModel: viewModel))
        }
    }

    private func pairingViewController() -> UIViewController {
        guard let pumpManager else {
            let label = UILabel()
            label.text = "Missing pump manager"
            label.textAlignment = .center
            return UIViewController()
        }
        let viewModel = EquilPairingViewModel(pumpManager: pumpManager)
        let view = EquilPairingView(viewModel: viewModel) { [weak self] in
            guard let self, let pumpManager = self.pumpManager else { return }
            if !pumpManager.isOnboarded {
                pumpManager.state.isOnboarded = true
                pumpManager.notifyStateDidChange()
                pumpManagerOnboardingDelegate?.pumpManagerOnboarding(didCreatePumpManager: pumpManager)
            }
            if self.isOnboardingFlow {
                self.navigateTo(.patchPrimingScreen)
            } else {
                self.resetNavigationTo([.settingsScreen, .patchPrimingScreen])
            }
        }
        return hostingController(rootView: view, title: "Pairing")
    }

    private func hostingController<Content: View>(
        rootView: Content,
        title: String? = nil
    ) -> DismissibleHostingController<some View> {
        let content = rootView
            .environment(\.appName, Bundle.main.bundleDisplayName)
        let hosting = DismissibleHostingController(content: content, colorPalette: colorPalette)
        if let title {
            hosting.title = title
        }
        return hosting
    }

    override public func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private var isOnboardingFlow: Bool {
        pumpManagerOnboardingDelegate != nil && !opensSettingsDashboard
    }

    private func pumpRemoval() {
        NotificationManager.clearPendingNotifications()
        guard let completionDelegate, let pumpManager else { return }
        pumpManager.notifyDelegateOfDeactivation {
            DispatchQueue.main.async {
                completionDelegate.completionNotifyingDidComplete(self)
            }
        }
    }

    private func finishOnboarding() {
        guard let pumpManager else { return }
        pumpManagerOnboardingDelegate?.pumpManagerOnboarding(didOnboardPumpManager: pumpManager)
        guard !opensSettingsDashboard else { return }
        completionDelegate?.completionNotifyingDidComplete(self)
    }
}

extension EquilUICoordinator {
    /// Must not navigate away from priming screen while fill-loop or active priming-flow latch.
    private func isPrimingNavigationBlocked() -> Bool {
        guard let pumpManager else { return false }
        return pumpManager.isPrimingActive || pumpManager.isPrimingFlowLatched
    }

    private func isLeavingPrimingScreen(targetScreens: [EquilUIScreen]) -> Bool {
        screenStack.contains(.patchPrimingScreen) && !targetScreens.contains(.patchPrimingScreen)
    }

    private func isLeavingPrimingScreen(targetScreen: EquilUIScreen) -> Bool {
        screenStack.last == .patchPrimingScreen && targetScreen != .patchPrimingScreen
    }

    func navigateTo(_ screen: EquilUIScreen) {
        if isLeavingPrimingScreen(targetScreen: screen), isPrimingNavigationBlocked() {
            return
        }
        if screen != .patchPrimingScreen {
            primingFromDashboard = false
        }
        screenStack.append(screen)
        let viewController = viewControllerForScreen(screen)
        viewController.isModalInPresentation = false
        pushViewController(viewController, animated: true)
    }

    func resetNavigationTo(_ screens: [EquilUIScreen]) {
        if isLeavingPrimingScreen(targetScreens: screens), isPrimingNavigationBlocked() {
            return
        }
        screenStack = screens
        let viewControllers = screenStack.map {
            let viewController = viewControllerForScreen($0)
            viewController.isModalInPresentation = false
            return viewController
        }
        setViewControllers(viewControllers, animated: true)
    }
}
