import LoopKit

class PatchPrimingViewModel: ObservableObject {
    private let processQueue = DispatchQueue(label: "com.nightscout.medtrumkit.primingView")

    @Published var isPriming = false
    @Published var primeProgress: Double = 0
    @Published var primingError = ""
    @Published var is300u = false

    /// true from first real flow start (ViewModel-level latch; pumpManager
    /// `isPrimingFlowLatched` survives VC rebuild too).
    private var isInPrimingFlow = false
    /// One-time entry check: if pump already primed, can advance — but NOT on every
    /// heartbeat/sync update (that caused early navigation during priming).
    private var didCheckAlreadyPrimedOnEntry = false
    /// One-time navigation after successful priming (completion + observer backup).
    private var didFinishPrimingNavigation = false

    private let nextStep: () -> Void
    let previousStep: () -> Void
    private let done: () -> Void
    private let fromDashboard: Bool
    private let pumpManager: EquilPumpManager?
    init(
        _ pumpManager: EquilPumpManager?,
        _ nextStep: @escaping () -> Void,
        _ previousStep: @escaping () -> Void,
        _ done: @escaping () -> Void,
        fromDashboard: Bool = false
    ) {
        self.pumpManager = pumpManager
        self.nextStep = nextStep
        self.previousStep = previousStep
        self.done = done
        self.fromDashboard = fromDashboard

        guard let pumpManager = self.pumpManager else {
            return
        }

        is300u = pumpManager.state.pumpName.contains("300U")
        restorePrimingUIState(from: pumpManager)
        pumpManager.addStatusObserver(self, queue: processQueue)
    }

    deinit {
        pumpManager?.removeStatusObserver(self)
    }

    /// After VC/ViewModel rebuild (e.g. resetNavigationTo) restore priming UI if
    /// fill-loop or pumpManager latch still active.
    func handleAppear() {
        guard let pumpManager else { return }
        restorePrimingUIState(from: pumpManager)
        checkAlreadyPrimedOnEntryIfNeeded()
    }

    private func restorePrimingUIState(from pumpManager: EquilPumpManager) {
        if pumpManager.isPrimingActive || pumpManager.isPrimingFlowLatched {
            isInPrimingFlow = true
            if pumpManager.isPrimingActive {
                isPriming = true
            }
            primeProgress = Double(pumpManager.state.primeProgress) / 240
        }
    }

    private func checkAlreadyPrimedOnEntryIfNeeded() {
        guard !didCheckAlreadyPrimedOnEntry else { return }
        didCheckAlreadyPrimedOnEntry = true

        guard let pumpManager else { return }
        guard !isInPrimingFlow, !pumpManager.isPrimingActive, !pumpManager.isPrimingFlowLatched else {
            return
        }

        if pumpManager.state.pumpState.rawValue > PatchState.priming.rawValue,
           pumpManager.state.pumpState.rawValue < PatchState.active.rawValue
        {
            pumpManager.removeStatusObserver(self)
            if fromDashboard {
                done()
            } else {
                nextStep()
            }
        } else if pumpManager.state.pumpState.rawValue >= PatchState.active.rawValue {
            pumpManager.removeStatusObserver(self)
            done()
        }
    }

    func startPrime() {
        #if targetEnvironment(simulator)
            pumpManager?.state.sessionToken = Crypto.genSessionToken()
            pumpManager?.state.pumpState = .primed
            pumpManager?.notifyStateDidChange()
            if fromDashboard {
                done()
            } else {
                nextStep()
            }
        #else
            guard let pumpManager = self.pumpManager else {
                nextStep()
                return
            }

            isPriming = true
            isInPrimingFlow = true
            primingError = ""
            pumpManager.primePatch { result in
                DispatchQueue.main.async {
                    if case let .failure(error) = result {
                        self.primingError = error.description
                        self.isPriming = false
                        return
                    }
                    // Fill-loop completed — pumpState update in primePatch
                    // may arrive up to 1.5s late; finishPrimingIfReady waits/retries until then.
                    self.finishPrimingIfReady(from: pumpManager)
                }
            }
        #endif
    }

    /// After successful priming navigate to next step / dashboard. Between fill-loop end and
    /// `pumpState = .primed` there may be short delay (primePatch 1.5s settle).
    private func finishPrimingIfReady(from pumpManager: EquilPumpManager, attempt: Int = 0) {
        guard !didFinishPrimingNavigation else { return }
        guard isInPrimingFlow else { return }
        guard !pumpManager.isPrimingActive else { return }

        // During active priming flow ONLY actual pumpState primed means complete.
        // Old activationProgress (> priming) caused early navigation on start,
        // before fill-loop started (notifyStateDidChange → observer race).
        let primingDone = pumpManager.state.pumpState.rawValue >= PatchState.primed.rawValue

        if primingDone {
            didFinishPrimingNavigation = true
            isPriming = false
            pumpManager.removeStatusObserver(self)
            pumpManager.unlatchPrimingFlow()
            if fromDashboard {
                done()
            } else {
                nextStep()
            }
            return
        }

        // primePatch asyncAfter settle: max ~3s wait, then error message.
        guard attempt < 6 else {
            isPriming = false
            primingError = String(
                localized: "Priming finished but pump state did not update. Try syncing or restart priming.",
                comment: "Error when fill loop succeeded but UI state stayed on priming"
            )
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.finishPrimingIfReady(from: pumpManager, attempt: attempt + 1)
        }
    }

    func cancelPriming() {
        pumpManager?.cancelPriming()
        DispatchQueue.main.async {
            self.isPriming = false
            self.primingError = String(
                localized: "Priming stopped",
                comment: "Message shown after the user stops priming"
            )
        }
    }
}

extension PatchPrimingViewModel: PumpManagerStatusObserver {
    func pumpManager(
        _ pumpManager: any LoopKit.PumpManager,
        didUpdate _: LoopKit.PumpManagerStatus,
        oldStatus _: LoopKit.PumpManagerStatus
    ) {
        #if targetEnvironment(simulator)
            DispatchQueue.main.async {
                self.isPriming = false
            }
        #else
            guard let pumpManager = self.pumpManager else {
                return
            }

            DispatchQueue.main.async {
                self.primeProgress = Double(pumpManager.state.primeProgress) / 240

                // During fill-loop only progress — navigation FORBIDDEN (heartbeat/sync must not kick out).
                guard !pumpManager.isPrimingActive else { return }
                // If loop stopped and pumpState became primed, navigate here too
                // (backup alongside completion handler).
                self.finishPrimingIfReady(from: pumpManager)
            }
        #endif
    }
}
