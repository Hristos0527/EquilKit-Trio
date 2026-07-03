import Foundation

/// Sequential Equil BLE command orchestration (AAPS `EquilManager` + command queue).
/// Handoff `runCommand` behaviour: connect-per-command, preempt cancel, zeroValueAck, settle delay.
public final class EquilCommandQueue {
    public struct CommandResult {
        public let success: Bool
        public let enacted: Bool
        public let errorMessage: String?

        public static func success(enacted: Bool = true) -> CommandResult {
            CommandResult(success: true, enacted: enacted, errorMessage: nil)
        }

        public static func failure(_ message: String) -> CommandResult {
            CommandResult(success: false, enacted: false, errorMessage: message)
        }
    }

    public struct CommandOptions {
        public var zeroValueAck: Bool
        public var ackWait: TimeInterval
        public var allowPreempt: Bool
        public var cmdTimeout: TimeInterval
        /// Ha igaz: a connect-per-command notify-flush a RÖVID (fastReconnect) profillal fut,
        /// és a parancs-utáni settle is rövidebb → ~2 mp/lépés reconnect-floor. A priming
        /// fill-loop állítja be (CmdStepSet / CmdResistanceGet). Bolus/temp/model: false (konzervatív).
        public var fastReconnect: Bool

        public init(
            zeroValueAck: Bool = false,
            ackWait: TimeInterval = 3.0,
            allowPreempt: Bool = false,
            cmdTimeout: TimeInterval = 40,
            fastReconnect: Bool = false
        ) {
            self.zeroValueAck = zeroValueAck
            self.ackWait = ackWait
            self.allowPreempt = allowPreempt
            self.cmdTimeout = cmdTimeout
            self.fastReconnect = fastReconnect
        }

        public static let `default` = CommandOptions()

        /// A priming fill-loop parancsainak opciói: per-parancs timeout (retry-hez elég türelmes),
        /// gyors notify-flush + rövid settle. A connect-per-command STABIL marad, csak a
        /// felesleges várakozás megy. A 15s cmdTimeout túl szűk volt resistance dupla-olvasás +
        /// session-quiesce mellett → időnként „timeout / BLE connection timeout”.
        public static let fillFast = CommandOptions(cmdTimeout: 25, fastReconnect: true)
    }

    /// AAPS `EquilManager.OLD_PUMP_SERIAL_PREFIXES`
    public static let oldPumpSerialPrefixes: Set<Character> = ["0", "1", "3", "A", "D"]

    private let workQueue = DispatchQueue(label: "com.equil.commandQueue")
    private let ble: EquilBLEManager
    private let runner: EquilCommandRunner
    private var pipelineBusy = false
    private var pendingBlocks: [() -> Void] = []
    private var commandInFlight = false
    /// Aktív connect-per-command fázis megszakítása (priming cancel / delete takeover).
    /// A connect-timeout várakozás alatt a runner.abort() no-op — ezt hívjuk cancelPriming-ből.
    private var activeConnectCancel: (() -> Void)?

    // MARK: - FILL-LOOP CANCEL (priming Stop gomb / deactivate force-takeover)

    /// Igaz, amíg auto fill-loop (priming) fut. A `cancelPriming()` ezt nézi, hogy van-e mit
    /// megszakítani, és a futó parancs abort-ját kell-e elvégeznie.
    private var fillLoopActive = false
    /// Ha igaz: a fill-loop a következő iteráció/retry ELŐTT tisztán leáll (nem indít több
    /// lépést/retry-t). A `cancelPriming()` állítja be; a `runFill` nullázza új priming indításkor.
    private var fillCancelled = false

    /// A `fillLoopActive` SZÁLBIZTOS tükre a UI számára (a UI fő szálról olvassa, a flag a
    /// workQueue-n mutálódik). A priming képernyő ezt nézi: amíg a fill-loop AKTÍV (a háttérben
    /// fut a StepSet→Resistance lánc), a státusz-observer NEM navigál el — különben egy köztes
    /// státusz-frissítés (pl. dashboard-sync) idő előtt a dashboardra ugratná a UI-t. Lock-mentes
    /// olvasás: a `os_unfair_lock` helyett egy egyszerű, atomi `Bool` írás/olvasás külön lockkal.
    private let fillLoopFlagLock = NSLock()
    private var fillLoopActivePublished = false

    /// Igaz, amíg a priming fill-loop ténylegesen FUT (szálbiztosan olvasható bárhonnan).
    public var isPrimingFillActive: Bool {
        fillLoopFlagLock.lock(); defer { fillLoopFlagLock.unlock() }
        return fillLoopActivePublished
    }

    /// A `fillLoopActive` ÉS a szálbiztos tükör együttes beállítása (mindig ezen keresztül).
    private func setFillLoopActive(_ active: Bool) {
        fillLoopActive = active
        fillLoopFlagLock.lock()
        fillLoopActivePublished = active
        fillLoopFlagLock.unlock()
    }

    private let bleNextCmdDelay: TimeInterval = Double(EquilConst.EQUIL_BLE_NEXT_CMD) / 1000.0

    /// Connect-per-command parancs-utáni settle a bontás (disconnect) UTÁN, MIELŐTT a következő
    /// lépés connect-je indul. A teljes 0,5s (bleNextCmdDelay) felesleges volt: a connectForCommand
    /// úgyis újracsatlakozik, ott már nincs külön settle (isConnected==false). Itt elég egy rövid
    /// köz, hogy az iOS a bontást feldolgozza — a fill-loop fastReconnect parancsai ezt használják.
    private let fastReconnectSettle: TimeInterval = 0.15

    // MARK: - FILL-LOOP AUTO-RETRY

    /// A priming fill-loop egy lépésének (CmdStepSet / CmdResistanceGet) MAXIMÁLIS automatikus
    /// újrapróbálkozása timeout/disconnect/communication hiba esetén, MIELŐTT valódi hibát jelez.
    /// Így a loop magától folytatódik, nem kell kézzel újranyomni a prime-ot.
    private static let fillMaxAttempts = 7

    /// BLE connect timeout. A háttérbeli loop (iOS throttling + GATT discovery + konzervatív
    /// notify-flush) gyakran túllépi a korábbi 15s-t; a priming 25s-e bizonyítottan elég.
    /// Bolus/temp/sync/loop ugyanezt a küszöböt kapja (fastReconnect továbbra is 25s).
    private static let defaultConnectionTimeout: TimeInterval = 25
    private static let primingConnectionTimeout: TimeInterval = 25

    /// Backoff a fill-retry-k között. ALSÓ KÜSZÖB = EQUIL_BLE_NEXT_CMD (0,5s): egy hibás/
    /// fragmentált olvasás után a következő próba connectje ELŐTT legalább 500 ms teljen el,
    /// hogy a pumpa ~390 ms-es ismétlési ciklusa elcsendesedjen (ne szivárogjon stale-frame).
    /// Onnan rövid exponenciális emelkedés, 2,0s plafonnal: 0,5 → 0,6 → 1,2 → 2,0.
    private static func fillRetryBackoff(attempt: Int) -> TimeInterval {
        let floor = Double(EquilConst.EQUIL_BLE_NEXT_CMD) / 1000.0
        return min(max(floor, 0.3 * pow(2.0, Double(attempt))), 2.0)
    }

    public var equilDevice: String = ""
    public var equilPassword: String = ""
    public var serialNumber: String = ""
    public var peripheralUUID: String?

    public var onLog: ((String) -> Void)?

    public init(ble: EquilBLEManager = EquilBLEManager(), runner: EquilCommandRunner? = nil) {
        self.ble = ble
        self.runner = runner ?? EquilCommandRunner(ble: ble)
        self.runner.onLog = { [weak self] in self?.log($0) }
    }

    public var bleManager: EquilBLEManager { ble }

    /// Firmware read during the last pairing flow (CmdDevicesOldGet).
    public var pairFirmwareVersion: String { runner.pairFirmwareVersion }

    public static func resistanceThreshold(for serialNumber: String) -> Int {
        let suffix = serialNumber.components(separatedBy: " - ").last ?? serialNumber
        let first = suffix.uppercased().first
        return first.map { oldPumpSerialPrefixes.contains($0) ? 500 : 220 } ?? 220
    }

    // MARK: - Generic execution

    public func executeCmd(
        _ makeCommand: @escaping () -> EquilCommandDriving,
        timeout: TimeInterval = 30,
        options: CommandOptions = .default,
        completion: @escaping (CommandResult) -> Void
    ) {
        enqueue(allowPreempt: options.allowPreempt) {
            self.runSingleCommand(
                makeCommand(),
                timeout: timeout,
                options: options,
                completion: completion
            )
        }
    }

    /// Ugyanaz mint `executeCmd`, de szinkron enqueue a workQueue-n (delete/unpair takeover után).
    func executeCmdOnWorkQueue(
        _ makeCommand: @escaping () -> EquilCommandDriving,
        timeout: TimeInterval = 30,
        options: CommandOptions = .default,
        completion: @escaping (CommandResult) -> Void
    ) {
        enqueueOnWorkQueue(allowPreempt: options.allowPreempt) {
            self.runSingleCommand(
                makeCommand(),
                timeout: timeout,
                options: options,
                completion: completion
            )
        }
    }

    public func executeCmdSequence(
        _ commands: [() -> EquilCommandDriving],
        timeout: TimeInterval = 30,
        options: CommandOptions = .default,
        completion: @escaping (CommandResult) -> Void
    ) {
        guard !commands.isEmpty else {
            completion(.success())
            return
        }
        enqueue(allowPreempt: options.allowPreempt) {
            self.runSequence(commands, index: 0, timeout: timeout, options: options, completion: completion)
        }
    }

    // MARK: - DOSING AUTO-RETRY (bolus / temp basal)

    /// Bolus és temp basal parancsok automatikus újrapróbálkozása BLE timeout/disconnect esetén.
    /// Egyszerűbb, mint a fill-retry: max 2 auto-retry (3 próba összesen), rövid backoff,
    /// bontás + index reset a következő connect előtt. A `makeCommand` MINDEN próbánál friss
    /// parancsot épít (friss createTime).
    private static let dosingMaxAttempts = 3

    public func executeCmdWithRetry(
        _ makeCommand: @escaping () -> EquilCommandDriving,
        timeout: TimeInterval = 30,
        options: CommandOptions = .default,
        attempt: Int = 0,
        completion: @escaping (CommandResult) -> Void
    ) {
        executeCmd(makeCommand, timeout: timeout, options: options) { [weak self] result in
            guard let self else { completion(result); return }
            if result.success {
                completion(result)
                return
            }
            let nextAttempt = attempt + 1
            if nextAttempt >= Self.dosingMaxAttempts {
                self.log("DOSING: retry kimerült (\(nextAttempt)/\(Self.dosingMaxAttempts)) — \(result.errorMessage ?? "ismeretlen hiba")")
                completion(result)
                return
            }
            let backoff = Self.fillRetryBackoff(attempt: attempt)
            self.log("DOSING: hiba (\(result.errorMessage ?? "?")) — auto-retry \(nextAttempt + 1)/\(Self.dosingMaxAttempts) \(Int(backoff * 1000))ms múlva")
            self.workQueue.asyncAfter(deadline: .now() + backoff) {
                self.recoverCommErrorOnWorkQueue(reason: result.errorMessage ?? "comm error")
                self.executeCmdWithRetry(
                    makeCommand,
                    timeout: timeout,
                    options: options,
                    attempt: nextAttempt,
                    completion: completion
                )
            }
        }
    }

    // MARK: - Pairing

    public func runPairing(
        serialNumber: String,
        password: String,
        maxBolus: Double,
        maxBasal: Double,
        timeout: TimeInterval = 90,
        completion: @escaping (CommandResult) -> Void
    ) {
        self.serialNumber = serialNumber
        enqueue {
            self.configureScanFilter()
            self.runner.runPairing(
                serialNumber: serialNumber,
                password: password,
                maxBolus: maxBolus,
                maxBasal: maxBasal,
                timeout: timeout
            ) { outcome in
                switch outcome {
                case let .success(enacted):
                    self.equilDevice = self.runner.pairedDevice ?? ""
                    self.equilPassword = self.runner.pairedPassword ?? ""
                    completion(.success(enacted: enacted))
                case let .failure(message):
                    completion(.failure(message))
                }
                self.finishPipeline()
            }
        }
    }

    // MARK: - Activation helpers

    /// A priming auto fill-loopban a resistance-ellenőrzés gyakorisága: a `CmdResistanceGet`
    /// MINDEN lépésnél fut (connect-per-command: StepSet és ResistanceGet külön connect).
    /// A küszöb-átlépést a `readResistanceConfirmed` dupla-olvasása továbbra is megerősíti.
    private static let resistanceCheckEvery = 1

    /// Egy fill-parancs futtatása AUTO-RETRY-vel: timeout/disconnect/communication hibánál
    /// automatikusan újrapróbálja UGYANAZT a parancsot (friss connect + parancs), rövid
    /// exponenciális backoff-fal, max `fillMaxAttempts`-szer. CSAK több egymás utáni sikertelen
    /// próba után jelez valódi hibát. A `makeCommand` MINDEN próbánál friss parancsot épít
    /// (friss createTime), hogy a pumpa ne dobja el elavult időbélyeg miatt.
    private func executeFillCmd(
        _ makeCommand: @escaping () -> EquilCommandDriving,
        attempt: Int = 0,
        completion: @escaping (CommandResult) -> Void
    ) {
        executeCmd(makeCommand, options: .fillFast) { [weak self] result in
            guard let self else { completion(result); return }
            if result.success {
                completion(result)
                return
            }
            // CANCEL-ELLENŐRZÉS retry ELŐTT: ha közben leállították a priming-et, NEM próbálunk újra.
            if self.fillCancelled {
                self.log("FILL: retry kihagyva (priming megszakítva)")
                completion(result)
                return
            }
            let nextAttempt = attempt + 1
            if nextAttempt >= Self.fillMaxAttempts {
                self.log("FILL: retry kimerült (\(nextAttempt)/\(Self.fillMaxAttempts)) — \(result.errorMessage ?? "ismeretlen hiba")")
                completion(result)
                return
            }
            let backoff = Self.fillRetryBackoff(attempt: attempt)
            self.log("FILL: lépés hiba (\(result.errorMessage ?? "?")) — auto-retry \(nextAttempt + 1)/\(Self.fillMaxAttempts) \(Int(backoff * 1000))ms múlva (reconnect + parancs)")
            self.workQueue.asyncAfter(deadline: .now() + backoff) {
                // A backoff letelte után is ellenőrizzük: cancel közben ne induljon új parancs.
                if self.fillCancelled {
                    self.log("FILL: retry elvetve a backoff után (priming megszakítva)")
                    completion(result)
                    return
                }
                // Fill retry recovery: bontás + index reset, majd friss connect (fastReconnect).
                self.recoverFillCommandOnWorkQueue(reason: result.errorMessage ?? "comm error")
                self.executeFillCmd(makeCommand, attempt: nextAttempt, completion: completion)
            }
        }
    }

    func runFillIteration(
        currentStep: Int,
        auto: Bool,
        iteration: Int = 0,
        stepSize: Int = EquilConst.EQUIL_STEP_FILL,
        completion: @escaping (CommandResult, Int, Int) -> Void
    ) {
        // SIMA PRIMING: a lépés mérete fix 320 (EQUIL_STEP_FILL) — a coarse-to-fine
        // (resistance-alapú lépéscsökkentés) ELTÁVOLÍTVA. A `stepSize` paraméter megmarad
        // (mindig 320-at kap), a BLE opcode/parancstartalom változatlan.
        let step = stepSize

        // AUTO PRIMING: ResistanceGet MINDEN StepSet ELŐTT (resistanceCheckEvery=1).
        // Ha a patch már primeolt / a küszöbön van, NEM lőjük a 320-as lépést.
        if auto {
            readResistanceConfirmed { resistanceResult, resistanceValue in
                guard resistanceResult.success else {
                    completion(resistanceResult, currentStep, resistanceValue)
                    return
                }
                if resistanceResult.enacted {
                    self.log("RESISTANCE: küszöb elérve ELŐTT StepSet (érték=\(resistanceValue)) — priming KÉSZ, lövés kihagyva")
                    completion(.success(enacted: true), currentStep, resistanceValue)
                    return
                }
                self.runFillStepSet(
                    currentStep: currentStep,
                    step: step,
                    completion: { stepResult, newStep in
                        completion(stepResult, newStep, resistanceValue)
                    }
                )
            }
            return
        }

        // Kézi fill: StepSet, majd resistance (régi sorrend).
        runFillStepSet(currentStep: currentStep, step: step) { stepResult, newStep in
            guard stepResult.success else {
                completion(stepResult, currentStep, -1)
                return
            }
            self.readResistanceConfirmed { resistanceResult, resistanceValue in
                completion(resistanceResult, newStep, resistanceValue)
            }
        }
    }

    /// Egy fill-lépés CmdStepSet (auto-retry-vel). A resistance-ellenőrzés a hívó felelőssége.
    private func runFillStepSet(
        currentStep: Int,
        step: Int,
        completion: @escaping (CommandResult, Int) -> Void
    ) {
        let makeStep: () -> EquilCommandDriving = { [weak self] in
            CmdStepSet(
                sendConfig: false,
                step: step,
                createTime: self?.nowMillis() ?? 0,
                equilDevice: self?.equilDevice ?? "",
                equilPassword: self?.equilPassword ?? ""
            )
        }
        log("FILL: lépés step=\(step) (kumulatív \(currentStep)→\(currentStep + step))")
        executeFillCmd(makeStep) { stepResult in
            guard stepResult.success else {
                completion(stepResult, currentStep)
                return
            }
            let newStep = currentStep + step
            if newStep > EquilConst.EQUIL_STEP_MAX {
                completion(.failure("Maximum fill step exceeded"), newStep)
                return
            }
            completion(.success(enacted: false), newStep)
        }
    }

    public func runFill(
        auto: Bool,
        startingStep: Int = 0,
        completion: @escaping (CommandResult) -> Void
    ) {
        // CONNECT-PER-COMMAND PRIMING (AAPS minta): minden CmdStepSet ÉS CmdResistanceGet
        // külön connect → parancs → disconnect; fastReconnect notify-flush + 0,15s settle
        // (~1–2 mp/parancs, ~2–4 mp/lépés StepSet+Resistance). Held-open session eltávolítva.
        // NAV-GUARD: a publikált priming-flag AZONNAL, SZINKRON igaz — MIELŐTT a workQueue-ra
        // lépnénk, hogy a status-observer a startPrime pillanatától aktív priminget lát.
        fillLoopFlagLock.lock()
        fillLoopActivePublished = true
        fillLoopFlagLock.unlock()
        workQueue.async {
            self.fillLoopActive = true
            self.fillCancelled = false
            self.log("PRIMING FILL: START (connect-per-command, fastReconnect, resistanceCheckEvery=\(Self.resistanceCheckEvery))")
            let startLoop = {
                self.runFillLoop(
                    auto: auto,
                    startingStep: startingStep,
                    nextStepSize: auto ? EquilConst.EQUIL_STEP_FILL : EquilConst.EQUIL_STEP_MANUAL
                ) { result in
                    self.disconnectFillLoopCleanupOnWorkQueue()
                    self.setFillLoopActive(false)
                    completion(result)
                }
            }
            // AUTO: indulás előtti resistance — már primeolt patch esetén NE lőjön StepSet-et.
            if auto {
                let threshold = Self.resistanceThreshold(for: self.serialNumber)
                self.log("PRIMING: indulás előtti resistance ellenőrzés (küszöb=\(threshold))")
                self.readResistanceConfirmed { preResult, preValue in
                    if self.fillCancelled {
                        self.disconnectFillLoopCleanupOnWorkQueue()
                        self.setFillLoopActive(false)
                        completion(.failure("Priming megszakítva"))
                        return
                    }
                    guard preResult.success else {
                        self.disconnectFillLoopCleanupOnWorkQueue()
                        self.setFillLoopActive(false)
                        completion(preResult)
                        return
                    }
                    if preResult.enacted {
                        self.log("PRIMING: már primeolt (érték=\(preValue), küszöb=\(threshold)) — StepSet kihagyva, activation következik")
                        self.disconnectFillLoopCleanupOnWorkQueue()
                        self.setFillLoopActive(false)
                        completion(.success(enacted: true))
                        return
                    }
                    self.log("PRIMING: indulás OK (érték=\(preValue), küszöb=\(threshold)) — fill-loop indul")
                    startLoop()
                }
            } else {
                startLoop()
            }
        }
    }

    /// PRIMING STOP/CANCEL: a futó fill-loopot tisztán leállítja, a folyamatban lévő BLE-parancsot
    /// megszakítja, a függő (nem futó) blokkokat eldobja, és bontja a kapcsolatot — hogy a queue
    /// AZONNAL szabad legyen az új parancsoknak (Delete Pump / deactivate / unpair). A futó parancs
    /// normál finish-lánca szabadítja fel a pipeline-t (nem nyúlunk a pipelineBusy-hoz itt, hogy ne
    /// ütközzön). A `fillCancelled` megakadályozza a további iterációt/retry-t.
    public func cancelPriming() {
        workQueue.async {
            self.cancelPrimingOnWorkQueue(clearPendingBlocks: true)
        }
    }

    /// Atomikus priming-leállítás + azonnali parancs (retract/stop/unpair). Egy workQueue-blokkban
    /// fut, hogy a cancel `pendingBlocks.removeAll()` ne dobja el a delete/unpair retract-jét.
    func executeAfterPrimingCancelled(_ block: @escaping () -> Void) {
        workQueue.async {
            self.cancelPrimingOnWorkQueue(clearPendingBlocks: true)
            block()
        }
    }

    /// Priming cancel belső implementáció (mindig a workQueue-n hívandó).
    private func cancelPrimingOnWorkQueue(clearPendingBlocks: Bool) {
        fillCancelled = true
        log("PRIMING: STOP/CANCEL — fill-loop leáll, futó parancs megszakítva, queue ürítve")
        if clearPendingBlocks {
            pendingBlocks.removeAll()
        }
        activeConnectCancel?()
        activeConnectCancel = nil
        ble.onReady = nil
        ble.onConnected = nil
        ble.stopScan()
        runner.abort()
        disconnectFillLoopCleanupOnWorkQueue()
        setFillLoopActive(false)
    }

    /// A rekurzív fill-munkavégző (NEM nyit/zár session-t — azt a `runFill` kezeli egyszer).
    /// `iteration`: 0-bázisú lépésszámláló; auto módban minden iteráció ELŐTT ResistanceGet fut.
    private func runFillLoop(
        auto: Bool,
        startingStep: Int,
        iteration: Int = 0,
        nextStepSize: Int = EquilConst.EQUIL_STEP_FILL,
        completion: @escaping (CommandResult) -> Void
    ) {
        // CANCEL-ELLENŐRZÉS minden iteráció ELŐTT: ha a felhasználó leállította a priming-et,
        // tisztán kilépünk (nem indítunk több lépést). A priming-flag-et NEM itt nullázzuk —
        // a `runFill` completion-wrapper-e törli EGYSZER a teljes loop legvégén.
        if fillCancelled {
            log("PRIMING: fill-loop leállt (cancel) — \(startingStep) lépésnél")
            completion(.failure("Priming megszakítva"))
            return
        }
        runFillIteration(
            currentStep: startingStep,
            auto: auto,
            iteration: iteration,
            stepSize: nextStepSize
        ) { result, step, resistance in
            guard result.success else {
                completion(result)
                return
            }
            if result.enacted {
                completion(.success(enacted: true))
                return
            }
            // Cancel a lépés és a következő iteráció között is megszakít.
            if self.fillCancelled {
                self.log("PRIMING: fill-loop leállt (cancel) — \(step) lépésnél")
                completion(.failure("Priming megszakítva"))
                return
            }
            if auto {
                // SIMA PRIMING: MINDEN lépés fix 320-as adag (EQUIL_STEP_FILL).
                // Resistance minden lépésnél; a küszöb-átlépést readResistanceConfirmed erősíti.
                _ = resistance
                self.runFillLoop(
                    auto: true,
                    startingStep: step,
                    iteration: iteration + 1,
                    nextStepSize: EquilConst.EQUIL_STEP_FILL,
                    completion: completion
                )
            } else {
                completion(.success(enacted: false))
            }
        }
    }

    /// Fill-loop lezárás / cancel után: bontás, hogy ne maradjon nyitott kapcsolat.
    private func disconnectFillLoopCleanupOnWorkQueue() {
        ble.onReady = nil
        ble.onConnected = nil
        if ble.isConnected { ble.disconnect() }
    }

    /// Fill-loop retry / confirm előtti cleanup: bontás + index reset, hogy a következő
    /// connect-per-command lépés tiszta fastReconnect útvonalon induljon.
    private func recoverFillCommandOnWorkQueue(reason: String) {
        guard fillLoopActive else { return }
        log("FILL: helyreállítás (\(reason)) — bontás + index reset")
        recoverCommErrorOnWorkQueue(reason: reason)
    }

    /// Közös BLE-helyreállítás dosing-retry (és fill-retry) előtt: bontás + index reset.
    private func recoverCommErrorOnWorkQueue(reason: String) {
        log("COMM: helyreállítás (\(reason)) — bontás + index reset")
        ble.onReady = nil
        ble.onConnected = nil
        runner.abort()
        if ble.isConnected { ble.disconnect() }
        EquilBaseCmd.resetState()
    }

    public func runAirStep(completion: @escaping (CommandResult) -> Void) {
        let cmd = CmdStepSet(
            sendConfig: false,
            step: EquilConst.EQUIL_STEP_AIR,
            createTime: nowMillis(),
            equilDevice: equilDevice,
            equilPassword: equilPassword
        )
        executeCmd({ cmd }, completion: completion)
    }

    public func runModelSet(_ mode: RunMode, completion: @escaping (CommandResult) -> Void) {
        let zeroAck = mode == .suspend
        let cmd = CmdModelSet(
            mode: mode.rawValue,
            createTime: nowMillis(),
            equilDevice: equilDevice,
            equilPassword: equilPassword
        )
        executeCmd(
            { cmd },
            options: CommandOptions(zeroValueAck: zeroAck)
        ) { completion($0) }
    }

    public func readResistance(completion: @escaping (CommandResult) -> Void) {
        readResistanceRaw { result, _ in completion(result) }
    }

    /// Resistance-olvasás a NYERS ÉRTÉKKEL együtt (logolás + coarse-to-fine döntés).
    /// A resistance-lekérdezés tiszta GET → az auto-retry teljesen biztonságos (idempotens).
    /// Minden próbánál friss parancs (friss createTime); a legutóbbi parancs `enacted`-jét és a
    /// dekódolt NYERS `resistance` értékét (data[6..7]) adjuk vissza. A nyers értéket a syslogba
    /// is kiírjuk: ebből validálható, fokozatosan nő-e a resistance (coarse-to-fine hatékony),
    /// vagy a küszöbre UGRIK (akkor a coarse-to-fine nem tud előre finomítani). -1 ha nem olvasható.
    private func readResistanceRaw(completion: @escaping (CommandResult, Int) -> Void) {
        let threshold = Self.resistanceThreshold(for: serialNumber)
        var lastCmd: CmdResistanceGet?
        let make: () -> EquilCommandDriving = { [weak self] in
            let cmd = CmdResistanceGet(
                resistanceThreshold: threshold,
                createTime: self?.nowMillis() ?? 0,
                equilDevice: self?.equilDevice ?? "",
                equilPassword: self?.equilPassword ?? ""
            )
            lastCmd = cmd
            return cmd
        }
        executeFillCmd(make) { [weak self] result in
            let value = lastCmd?.resistance ?? -1
            let enacted = lastCmd?.enacted ?? false
            if result.success {
                // NYERS RESISTANCE LOG (a "✓ cmdSuccess" mellett) — a fokozatos vs hirtelen
                // emelkedés validálásához. Ezt keresd a syslogban: "RESISTANCE: érték=…".
                self?.log("RESISTANCE: érték=\(value) (küszöb=\(threshold), enacted=\(enacted))")
            }
            completion(
                CommandResult(success: result.success, enacted: enacted, errorMessage: result.errorMessage),
                value
            )
        }
    }

    /// SAFETY / priming-complete VÉDELEM: a küszöb-átlépést (`enacted=true`) NEM fogadjuk el
    /// egyetlen resistance-olvasásból. Egy stale/romlott BLE-keret tévesen MAGAS resistance-nek
    /// dekódolódhat (data[6..7]), így a priming az ELSŐ lépés után késznek hihetné magát →
    /// alultöltés (levegő a vezetékben). Ezért ha az olvasás `enacted=true`-t ad, AZONNAL egy
    /// MEGERŐSÍTŐ (második, teljesen friss connect-per-command) olvasást végzünk; CSAK ha az is
    /// `enacted=true`, jelezzük késznek. Ha a megerősítés `enacted=false` (= az első gyanús/stale
    /// volt), a priming FOLYTATÓDIK (a legrosszabb eset egy plusz fill-lépés ≈ EQUIL_STEP_FILL —
    /// a BIZTONSÁGOS irány). Küszöb alatti olvasásnál (enacted=false) nincs mit megerősíteni.
    /// A GATT-cache visszavonása a gyökérok-javítás (friss discovery → tiszta olvasás); ez a
    /// megerősítés a védelem mélysége, ha máshol mégis becsúszna egy hibás keret.
    private func readResistanceConfirmed(completion: @escaping (CommandResult, Int) -> Void) {
        readResistanceRaw { [weak self] first, firstValue in
            guard let self else { completion(first, firstValue); return }
            guard first.success, first.enacted else {
                // Sikertelen olvasás (auto-retry már lefutott) VAGY küszöb alatt → ahogy van.
                completion(first, firstValue)
                return
            }
            self.log("RESISTANCE: küszöb-átlépés gyanú (1. olvasás enacted=true, érték=\(firstValue)) — MEGERŐSÍTŐ újraolvasás")
            // A 1. olvasás után még jöhetnek confirm-keretek — fill-recovery a workQueue-n.
            self.workQueue.async {
                self.recoverFillCommandOnWorkQueue(reason: "resistance confirm előtti drain")
                self.readResistanceRaw { second, secondValue in
                    guard second.success else {
                        self.log("RESISTANCE: megerősítő olvasás HIBA (\(second.errorMessage ?? "?")) — NEM kész")
                        completion(second, secondValue)
                        return
                    }
                    if second.enacted {
                        self.log("RESISTANCE: megerősítve (2/2 enacted=true, érték=\(secondValue)) — priming KÉSZ")
                        completion(.success(enacted: true), secondValue)
                    } else {
                        self.log("RESISTANCE: megerősítés ELMARADT (1. enacted, 2. nem, érték=\(secondValue)) — stale-gyanú, priming FOLYTATÓDIK")
                        completion(.success(enacted: false), secondValue)
                    }
                }
            }
        }
    }

    public func suspendDelivery(completion: @escaping (CommandResult) -> Void) {
        runModelSet(.suspend, completion: completion)
    }

    public func resumeDelivery(completion: @escaping (CommandResult) -> Void) {
        runModelSet(.run, completion: completion)
    }

    /// Preempt any in-flight command (bolus STOP). Same Cmd*, fresh connection after settle.
    public func preemptAndExecute(
        _ makeCommand: @escaping () -> EquilCommandDriving,
        timeout: TimeInterval = 30,
        options: CommandOptions = .default,
        completion: @escaping (CommandResult) -> Void
    ) {
        var opts = options
        opts.allowPreempt = true
        executeCmd(makeCommand, timeout: timeout, options: opts, completion: completion)
    }

    // MARK: - Private

    private func enqueue(allowPreempt: Bool = false, _ block: @escaping () -> Void) {
        workQueue.async {
            self.enqueueOnWorkQueue(allowPreempt: allowPreempt, block)
        }
    }

    /// Szinkron enqueue — csak workQueue-n (executeAfterPrimingCancelled után).
    private func enqueueOnWorkQueue(allowPreempt: Bool = false, _ block: @escaping () -> Void) {
        if pipelineBusy {
            if allowPreempt, commandInFlight, ble.isConnected {
                log("PREEMPT: clearing in-flight command")
                ble.onReady = nil
                ble.onConnected = nil
                ble.disconnect()
                commandInFlight = false
                workQueue.asyncAfter(deadline: .now() + bleNextCmdDelay) {
                    self.pipelineBusy = true
                    block()
                }
                return
            }
            pendingBlocks.append(block)
            return
        }
        pipelineBusy = true
        block()
    }

    private func finishPipeline() {
        workQueue.async {
            self.pipelineBusy = false
            self.commandInFlight = false
            if !self.pendingBlocks.isEmpty {
                let next = self.pendingBlocks.removeFirst()
                self.pipelineBusy = true
                next()
            }
        }
    }

    private func runSequence(
        _ commands: [() -> EquilCommandDriving],
        index: Int,
        timeout: TimeInterval,
        options: CommandOptions,
        completion: @escaping (CommandResult) -> Void
    ) {
        guard index < commands.count else {
            completion(.success())
            finishPipeline()
            return
        }
        runSingleCommand(commands[index](), timeout: timeout, options: options) { result in
            guard result.success else {
                completion(result)
                self.finishPipeline()
                return
            }
            self.workQueue.asyncAfter(deadline: .now() + self.bleNextCmdDelay) {
                self.runSequence(commands, index: index + 1, timeout: timeout, options: options, completion: completion)
            }
        }
    }

    private func runSingleCommand(
        _ command: EquilCommandDriving,
        timeout: TimeInterval,
        options: CommandOptions,
        completion: @escaping (CommandResult) -> Void
    ) {
        let cmdTimeout = max(timeout, options.cmdTimeout)
        let hardDeadline = cmdTimeout + 8
        var settled = false

        let finish: (CommandResult) -> Void = { [weak self] result in
            guard let self, !settled else { return }
            settled = true
            self.activeConnectCancel = nil
            self.ble.onReady = nil
            self.ble.onConnected = nil
            // Priming fill-loop: MINDIG connect-per-command — bontás minden parancs után
            // (fail-fast disconnect). A held-open session ág eltávolítva (~10,5s pump-disconnect).
            let wasConnected = self.ble.isConnected
            if wasConnected { self.ble.disconnect() }
            let settleDelay: TimeInterval = wasConnected
                ? (options.fastReconnect ? self.fastReconnectSettle : self.bleNextCmdDelay)
                : 0
            self.workQueue.asyncAfter(deadline: .now() + settleDelay) {
                self.commandInFlight = false
                completion(result)
                self.finishPipeline()
            }
        }

        workQueue.asyncAfter(deadline: .now() + hardDeadline) {
            if settled { return }
            finish(.failure("timeout (\(Int(hardDeadline))s) — pump not responding"))
        }

        let runCmd = { [weak self] in
            guard let self else { return }
            self.runner.run(command: command, timeout: cmdTimeout, resetIndices: true) { outcome in
                self.ble.pauseWatchdog()
                switch outcome {
                case let .success(enacted):
                    finish(.success(enacted: enacted))
                case let .failure(message):
                    finish(.failure(message))
                }
            }
            if options.zeroValueAck {
                self.workQueue.asyncAfter(deadline: .now() + options.ackWait) {
                    if settled { return }
                    finish(.success(enacted: true))
                }
            }
        }

        // Connect-per-command: minden parancs teljes connect → flush → parancs → disconnect ciklus.
        EquilBaseCmd.resetState()
        configureScanFilter()
        // Diagnosztikai scan (párosítás-lista) ne blokkolja a parancs-connectet.
        ble.diagnosticOnly = false
        ble.onDiscoverDiagnostic = nil
        commandInFlight = true
        // NOTIFY-FLUSH PROFIL: a fill-loop (fastReconnect) rövid drainnel zár (~1–2 mp/lépés),
        // a többi parancs a konzervatív (lassú pumpa-ürülésre is hagy időt) profillal fut.
        ble.notifyFlushProfile = options.fastReconnect ? .fastReconnect : .conservative
        ble.pauseWatchdog()

        var connArmed = true
        let connTimeout = DispatchWorkItem {
            guard connArmed else { return }
            connArmed = false
            finish(.failure("BLE connection timeout"))
        }
        activeConnectCancel = {
            guard connArmed else { return }
            connArmed = false
            connTimeout.cancel()
            finish(.failure("cancelled"))
        }
        let connectTimeout = options.fastReconnect
            ? Self.primingConnectionTimeout
            : Self.defaultConnectionTimeout
        workQueue.asyncAfter(deadline: .now() + connectTimeout, execute: connTimeout)

        ble.onReady = { [weak self] in
            guard let self, connArmed else { return }
            connArmed = false
            connTimeout.cancel()
            self.ble.onReady = nil
            runCmd()
        }

        if let uuid = peripheralUUID, let id = UUID(uuidString: uuid) {
            _ = ble.retrieveAndHold(identifier: id)
        }
        ble.nameFilterContains = serialNumber.isEmpty ? nil : serialNumber
        if ble.isConnected {
            ble.connectForCommand()
        } else if ble.currentPeripheral != nil {
            ble.connectForCommand()
        } else {
            ble.startScan()
        }
    }

    private func configureScanFilter() {
        ble.nameFilterPrefix = "Equil"
        ble.nameFilterContains = serialNumber.isEmpty ? nil : serialNumber
    }

    private func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func log(_ message: String) {
        onLog?(message)
    }
}
