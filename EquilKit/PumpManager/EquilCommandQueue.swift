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
        /// If true: connect-per-command notify-flush uses SHORT (fastReconnect) profile,
        /// and post-command settle is shorter → ~2s/step reconnect floor. Priming
        /// fill-loop sets this (CmdStepSet / CmdResistanceGet). Bolus/temp/model: false (conservative).
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

        /// Priming fill-loop command options: per-command timeout (patient enough for retry),
        /// fast notify-flush + short settle. connect-per-command stays STABLE, only
        /// excess wait removed. 15s cmdTimeout too tight for resistance double-read +
        /// session-quiesce → occasional "timeout / BLE connection timeout".
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
    /// Abort active connect-per-command phase (priming cancel / delete takeover).
    /// During connect-timeout wait runner.abort() is no-op — call this from cancelPriming.
    private var activeConnectCancel: (() -> Void)?

    // MARK: - FILL-LOOP CANCEL (priming Stop gomb / deactivate force-takeover)

    /// true while auto fill-loop (priming) runs. `cancelPriming()` checks if there is
    /// anything to abort and whether running command abort is needed.
    private var fillLoopActive = false
    /// If true: fill-loop stops cleanly BEFORE next iteration/retry (no more
    /// steps/retries). Set by `cancelPriming()`; `runFill` clears on new priming start.
    private var fillCancelled = false

    /// THREAD-SAFE mirror of `fillLoopActive` for UI (UI reads on main thread, flag mutates on
    /// workQueue). Priming screen checks: while fill-loop ACTIVE (StepSet→Resistance chain
    /// running in background), status observer must NOT navigate — otherwise intermediate
    /// status update (e.g. dashboard-sync) would jump UI to dashboard early. Lock-free
    /// read: simple atomic Bool read/write with separate lock instead of `os_unfair_lock`.
    private let fillLoopFlagLock = NSLock()
    private var fillLoopActivePublished = false

    /// true while priming fill-loop actually RUNS (thread-safe read from anywhere).
    public var isPrimingFillActive: Bool {
        fillLoopFlagLock.lock(); defer { fillLoopFlagLock.unlock() }
        return fillLoopActivePublished
    }

    /// Set `fillLoopActive` AND thread-safe mirror together (always via this).
    private func setFillLoopActive(_ active: Bool) {
        fillLoopActive = active
        fillLoopFlagLock.lock()
        fillLoopActivePublished = active
        fillLoopFlagLock.unlock()
    }

    private let bleNextCmdDelay: TimeInterval = Double(EquilConst.EQUIL_BLE_NEXT_CMD) / 1000.0

    /// Connect-per-command post-command settle AFTER disconnect, BEFORE next
    /// step connect starts. Full 0.5s (bleNextCmdDelay) was excess: connectForCommand
    /// reconnects anyway, no separate settle there (isConnected==false). Short gap here
    /// for iOS to process disconnect — fill-loop fastReconnect commands use this.
    private let fastReconnectSettle: TimeInterval = 0.15

    // MARK: - FILL-LOOP AUTO-RETRY

    /// MAX automatic retries for one priming fill-loop step (CmdStepSet / CmdResistanceGet)
    /// on timeout/disconnect/communication error, BEFORE reporting real failure.
    /// Loop continues on its own, no manual re-prime needed.
    private static let fillMaxAttempts = 7

    /// BLE connect timeout. Background loop (iOS throttling + GATT discovery + conservative
    /// notify-flush) often exceeded prior 15s; priming 25s proven sufficient.
    /// Bolus/temp/sync/loop get same threshold (fastReconnect still 25s).
    private static let defaultConnectionTimeout: TimeInterval = 25
    private static let primingConnectionTimeout: TimeInterval = 25

    /// Backoff between fill-retries. LOWER BOUND = EQUIL_BLE_NEXT_CMD (0.5s): after bad/
    /// fragmented read, at least 500ms before next attempt connect,
    /// so pump ~390ms repeat cycle quiesces (no stale-frame leak).
    /// Then short exponential rise, 2.0s cap: 0.5 → 0.6 → 1.2 → 2.0.
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

    /// Same as `executeCmd`, but synchronous enqueue on workQueue (after delete/unpair takeover).
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

    /// Auto-retry bolus and temp basal commands on BLE timeout/disconnect.
    /// Simpler than fill-retry: max 2 auto-retry (3 attempts total), short backoff,
    /// disconnect + index reset before next connect. `makeCommand` builds fresh
    /// command every attempt (fresh createTime).
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
                self.log("DOSING: retries exhausted (\(nextAttempt)/\(Self.dosingMaxAttempts)) — \(result.errorMessage ?? "unknown error")")
                completion(result)
                return
            }
            let backoff = Self.fillRetryBackoff(attempt: attempt)
            self.log("DOSING: error (\(result.errorMessage ?? "?")) — auto-retry \(nextAttempt + 1)/\(Self.dosingMaxAttempts) in \(Int(backoff * 1000))ms")
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

    /// Resistance check frequency in priming auto fill-loop: `CmdResistanceGet`
    /// runs EVERY step (connect-per-command: StepSet and ResistanceGet separate connect).
    /// Threshold crossing still confirmed by `readResistanceConfirmed` double-read.
    private static let resistanceCheckEvery = 1

    /// Run one fill command with AUTO-RETRY: on timeout/disconnect/communication error
    /// automatically retries SAME command (fresh connect + command), short
    /// exponential backoff, max `fillMaxAttempts` times. ONLY after multiple consecutive failed
    /// attempts reports real error. `makeCommand` builds fresh command EVERY attempt
    /// (fresh createTime) so pump does not reject stale timestamp.
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
            // CANCEL CHECK before retry: if priming stopped meanwhile, do NOT retry.
            if self.fillCancelled {
                self.log("FILL: retry skipped (priming cancelled)")
                completion(result)
                return
            }
            let nextAttempt = attempt + 1
            if nextAttempt >= Self.fillMaxAttempts {
                self.log("FILL: retries exhausted (\(nextAttempt)/\(Self.fillMaxAttempts)) — \(result.errorMessage ?? "unknown error")")
                completion(result)
                return
            }
            let backoff = Self.fillRetryBackoff(attempt: attempt)
            self.log("FILL: step error (\(result.errorMessage ?? "?")) — auto-retry \(nextAttempt + 1)/\(Self.fillMaxAttempts) in \(Int(backoff * 1000))ms (reconnect + command)")
            self.workQueue.asyncAfter(deadline: .now() + backoff) {
                // After backoff also check: do not start new command if cancelled.
                if self.fillCancelled {
                    self.log("FILL: retry dropped after backoff (priming cancelled)")
                    completion(result)
                    return
                }
                // Fill retry recovery: disconnect + index reset, then fresh connect (fastReconnect).
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
        // SIMPLE PRIMING: step size fixed 320 (EQUIL_STEP_FILL) — coarse-to-fine
        // (resistance-based step reduction) REMOVED. `stepSize` parameter remains
        // (always gets 320), BLE opcode/command payload unchanged.
        let step = stepSize

        // AUTO PRIMING: ResistanceGet BEFORE EVERY StepSet (resistanceCheckEvery=1).
        // If patch already primed / at threshold, do NOT fire 320 step.
        if auto {
            readResistanceConfirmed { resistanceResult, resistanceValue in
                guard resistanceResult.success else {
                    completion(resistanceResult, currentStep, resistanceValue)
                    return
                }
                if resistanceResult.enacted {
                    self.log("RESISTANCE: threshold reached BEFORE StepSet (value=\(resistanceValue)) — priming DONE, step skipped")
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

        // Manual fill: StepSet, then resistance (legacy order).
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

    /// One fill step CmdStepSet (with auto-retry). Caller responsible for resistance check.
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
        log("FILL: step step=\(step) (cumulative \(currentStep)→\(currentStep + step))")
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
        // CONNECT-PER-COMMAND PRIMING (AAPS pattern): every CmdStepSet AND CmdResistanceGet
        // separate connect → command → disconnect; fastReconnect notify-flush + 0.15s settle
        // (~1–2s/command, ~2–4s/step StepSet+Resistance). Held-open session removed.
        // NAV-GUARD: published priming-flag IMMEDIATELY, SYNC true — BEFORE dispatching to workQueue
        // so status-observer sees active priming from startPrime moment.
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
            // AUTO: pre-start resistance — if already primed patch do NOT fire StepSet.
            if auto {
                let threshold = Self.resistanceThreshold(for: self.serialNumber)
                self.log("PRIMING: pre-start resistance check (threshold=\(threshold))")
                self.readResistanceConfirmed { preResult, preValue in
                    if self.fillCancelled {
                        self.disconnectFillLoopCleanupOnWorkQueue()
                        self.setFillLoopActive(false)
                        completion(.failure("Priming cancelled"))
                        return
                    }
                    guard preResult.success else {
                        self.disconnectFillLoopCleanupOnWorkQueue()
                        self.setFillLoopActive(false)
                        completion(preResult)
                        return
                    }
                    if preResult.enacted {
                        self.log("PRIMING: already primed (value=\(preValue), threshold=\(threshold)) — StepSet skipped, activation next")
                        self.disconnectFillLoopCleanupOnWorkQueue()
                        self.setFillLoopActive(false)
                        completion(.success(enacted: true))
                        return
                    }
                    self.log("PRIMING: start OK (value=\(preValue), threshold=\(threshold)) — fill-loop starting")
                    startLoop()
                }
            } else {
                startLoop()
            }
        }
    }

    /// PRIMING STOP/CANCEL: cleanly stops running fill-loop, aborts in-flight BLE command,
    /// drops pending (non-running) blocks, disconnects — so queue
    /// is IMMEDIATELY free for new commands (Delete Pump / deactivate / unpair). Running command
    /// normal finish chain frees pipeline (do not touch pipelineBusy here to avoid
    /// conflict). `fillCancelled` prevents further iteration/retry.
    public func cancelPriming() {
        workQueue.async {
            self.cancelPrimingOnWorkQueue(clearPendingBlocks: true)
        }
    }

    /// Atomic priming stop + immediate command (retract/stop/unpair). One workQueue block
    /// so cancel `pendingBlocks.removeAll()` does not drop delete/unpair retract.
    func executeAfterPrimingCancelled(_ block: @escaping () -> Void) {
        workQueue.async {
            self.cancelPrimingOnWorkQueue(clearPendingBlocks: true)
            block()
        }
    }

    /// Priming cancel internal implementation (always call on workQueue).
    private func cancelPrimingOnWorkQueue(clearPendingBlocks: Bool) {
        fillCancelled = true
        log("PRIMING: STOP/CANCEL — fill-loop stopped, running command aborted, queue drained")
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

    /// Recursive fill worker (does NOT open/close session — `runFill` handles once).
    /// `iteration`: 0-based step counter; in auto mode ResistanceGet runs BEFORE every iteration.
    private func runFillLoop(
        auto: Bool,
        startingStep: Int,
        iteration: Int = 0,
        nextStepSize: Int = EquilConst.EQUIL_STEP_FILL,
        completion: @escaping (CommandResult) -> Void
    ) {
        // CANCEL CHECK before every iteration: if user stopped priming,
        // exit cleanly (no more steps). Do NOT clear priming-flag here —
        // `runFill` completion wrapper clears ONCE at full loop end.
        if fillCancelled {
            log("PRIMING: fill-loop stopped (cancel) — at step \(startingStep)")
            completion(.failure("Priming cancelled"))
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
            // Cancel also between step and next iteration.
            if self.fillCancelled {
                self.log("PRIMING: fill-loop stopped (cancel) — at step \(step)")
                completion(.failure("Priming cancelled"))
                return
            }
            if auto {
                // SIMPLE PRIMING: EVERY step fixed 320 unit (EQUIL_STEP_FILL).
                // Resistance every step; threshold crossing confirmed by readResistanceConfirmed.
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

    /// After fill-loop end / cancel: disconnect so no open connection remains.
    private func disconnectFillLoopCleanupOnWorkQueue() {
        ble.onReady = nil
        ble.onConnected = nil
        if ble.isConnected { ble.disconnect() }
    }

    /// Fill-loop retry / pre-confirm cleanup: disconnect + index reset so next
    /// connect-per-command step starts on clean fastReconnect path.
    private func recoverFillCommandOnWorkQueue(reason: String) {
        guard fillLoopActive else { return }
        log("FILL: recovery (\(reason)) — disconnect + index reset")
        recoverCommErrorOnWorkQueue(reason: reason)
    }

    /// Shared BLE recovery before dosing-retry (and fill-retry): disconnect + index reset.
    private func recoverCommErrorOnWorkQueue(reason: String) {
        log("COMM: recovery (\(reason)) — disconnect + index reset")
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

    /// Resistance read with RAW VALUE (logging + coarse-to-fine decision).
    /// Resistance query is pure GET → auto-retry fully safe (idempotent).
    /// Fresh command every attempt (fresh createTime); return latest command `enacted` and
    /// decoded RAW `resistance` value (data[6..7]). Raw value also logged to syslog
    /// to validate gradual resistance increase (coarse-to-fine effective),
    /// or JUMPS to threshold (then coarse-to-fine cannot refine ahead). -1 if unreadable.
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
                // for rise validation. Look in syslog: "RESISTANCE: value=…".
                self?.log("RESISTANCE: value=\(value) (threshold=\(threshold), enacted=\(enacted))")
            }
            completion(
                CommandResult(success: result.success, enacted: enacted, errorMessage: result.errorMessage),
                value
            )
        }
    }

    /// SAFETY / priming-complete GUARD: do NOT accept threshold crossing (`enacted=true`)
    /// from single resistance read. Stale/corrupt BLE frame may decode as falsely HIGH resistance
    /// (data[6..7]), so priming could think done after FIRST step →
    /// under-fill (air in line). So if read gives `enacted=true`, IMMEDIATELY run
    /// CONFIRMING (second, fully fresh connect-per-command) read; ONLY if that also
    /// `enacted=true`, signal complete. If confirm `enacted=false` (= first was suspicious/stale
    /// ), priming CONTINUES (worst case one extra fill step ≈ EQUIL_STEP_FILL —
    /// the SAFE direction). Below-threshold read (enacted=false) needs no confirm.
    /// GATT cache revert is root-cause fix (fresh discovery → clean read); this
    /// confirmation is defense in depth if bad frame slips through elsewhere.
    private func readResistanceConfirmed(completion: @escaping (CommandResult, Int) -> Void) {
        readResistanceRaw { [weak self] first, firstValue in
            guard let self else { completion(first, firstValue); return }
            guard first.success, first.enacted else {
                // Failed read (auto-retry done) OR below threshold → as-is.
                completion(first, firstValue)
                return
            }
            self.log("RESISTANCE: threshold crossing suspect (1st read enacted=true, value=\(firstValue)) — CONFIRMING re-read")
            // Confirm frames may still arrive after 1st read — fill-recovery on workQueue.
            self.workQueue.async {
                self.recoverFillCommandOnWorkQueue(reason: "pre-resistance confirm drain")
                self.readResistanceRaw { second, secondValue in
                    guard second.success else {
                        self.log("RESISTANCE: confirming read ERROR (\(second.errorMessage ?? "?")) — NOT complete")
                        completion(second, secondValue)
                        return
                    }
                    if second.enacted {
                        self.log("RESISTANCE: confirmed (2/2 enacted=true, value=\(secondValue)) — priming DONE")
                        completion(.success(enacted: true), secondValue)
                    } else {
                        self.log("RESISTANCE: confirm FAILED (1st enacted, 2nd not, value=\(secondValue)) — stale suspect, priming CONTINUES")
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

    /// Synchronous enqueue — workQueue only (after executeAfterPrimingCancelled).
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
            // Priming fill-loop: ALWAYS connect-per-command — disconnect after every command
            // (fail-fast disconnect). Held-open session path removed (~10.5s pump-disconnect).
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
        // Diagnostic scan (pairing list) must not block command connect.
        ble.diagnosticOnly = false
        ble.onDiscoverDiagnostic = nil
        commandInFlight = true
        // NOTIFY-FLUSH PROFILE: fill-loop (fastReconnect) closes with short drain (~1–2s/step),
        // other commands use conservative profile (allows slow pump drain time).
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
