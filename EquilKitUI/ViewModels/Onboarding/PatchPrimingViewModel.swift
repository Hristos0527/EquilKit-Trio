import LoopKit

class PatchPrimingViewModel: ObservableObject {
    private let processQueue = DispatchQueue(label: "com.nightscout.medtrumkit.primingView")

    @Published var isPriming = false
    @Published var primeProgress: Double = 0
    @Published var primingError = ""
    @Published var is300u = false

    /// A flow első valódi indításától igaz (ViewModel szintű latch; a pumpManager
    /// `isPrimingFlowLatched` flagje túléli a VC újraépítést is).
    private var isInPrimingFlow = false
    /// Egyszeri belépéskori ellenőrzés: ha a pumpa már primed, továbbléphetünk — de NEM minden
    /// heartbeat/sync frissítésnél (az okozta az idő előtti elnavigálást priming közben).
    private var didCheckAlreadyPrimedOnEntry = false
    /// Egyszeri navigáció a sikeres priming után (completion + observer backup).
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

    /// VC/ViewModel újraépítés után (pl. resetNavigationTo) visszaállítja a priming UI-t, ha a
    /// fill-loop vagy a pumpManager latch még aktív.
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
                    // A fill-loop sikeresen lefutott — a pumpState frissítése a primePatch-ben
                    // akár 1,5 s késleltetéssel érkezik; a finishPrimingIfReady addig vár/retry-el.
                    self.finishPrimingIfReady(from: pumpManager)
                }
            }
        #endif
    }

    /// Sikeres priming után navigál a következő lépésre / dashboardra. A fill-loop vége és a
    /// `pumpState = .primed` beállítása között lehet rövid késleltetés (primePatch 1,5 s settle).
    private func finishPrimingIfReady(from pumpManager: EquilPumpManager, attempt: Int = 0) {
        guard !didFinishPrimingNavigation else { return }
        guard isInPrimingFlow else { return }
        guard !pumpManager.isPrimingActive else { return }

        // Aktív priming flow alatt CSAK a tényleges pumpState primed jelenti a kész állapotot.
        // A régi activationProgress (> priming) idő előtti elnavigálást okozott induláskor,
        // mielőtt a fill-loop elindult volna (notifyStateDidChange → observer race).
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

        // primePatch asyncAfter settle: max ~3 s várakozás, aztán hibaüzenet.
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

                // Fill-loop alatt csak progress — navigáció TILOS (heartbeat/sync ne lökje ki).
                guard !pumpManager.isPrimingActive else { return }
                // Ha a loop már leállt és a pumpState primed-re vált, itt is navigálunk
                // (backup a completion handler mellé).
                self.finishPrimingIfReady(from: pumpManager)
            }
        #endif
    }
}
