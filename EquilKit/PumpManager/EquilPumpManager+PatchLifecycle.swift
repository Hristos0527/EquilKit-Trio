import Foundation
import LoopKit

extension EquilPumpManager {
    func activatePatch(_ completion: @escaping (EquilActivatePatchResult) -> Void) {
        guard !state.deviceToken.isEmpty else {
            completion(.failure(error: .connectionFailure(reason: "Pump not paired")))
            return
        }

        var capturedInsulin: CmdInsulinGet?
        commandQueue.executeCmdSequence([
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
                CmdModelSet(
                    mode: RunMode.run.rawValue,
                    createTime: Int64(Date().timeIntervalSince1970 * 1000),
                    equilDevice: self.state.deviceToken,
                    equilPassword: self.state.password
                )
            }
        ]) { result in
            guard result.success else {
                completion(.failure(error: .connectionFailure(reason: result.errorMessage ?? "Activation failed")))
                return
            }

            if let insulinCmd = capturedInsulin {
                self.state.reservoir = Double(insulinCmd.insulin)
                if self.state.initialReservoir == nil {
                    self.state.initialReservoir = self.state.reservoir
                }
            }

            if self.state.patchId.isEmpty, !self.state.serialNumber.isEmpty {
                self.state.patchId = Data(self.state.serialNumber.utf8)
            }

            let start = Date.now
            let resumeDose = UnfinalizedDose(resumeStartTime: start, insulinType: self.state.insulinType)
            self.emitPumpEvents([
                NewPumpEvent.replacedPump(date: start),
                NewPumpEvent.resume(dose: resumeDose.toDoseEntry(), date: resumeDose.startDate)
            ])

            self.state.basalDose = resumeDose
            self.state.runMode = .run
            self.state.pumpState = .active
            self.state.patchActivatedAt = start
            self.state.activationProgress = .completed
            self.state.isOnboarded = true
            self.state.isSuspended = false
            self.state.lastSync = Date.now
            self.notifyStateDidChange()
            self.emitReservoirLevel()
            completion(.success)
        }
    }

    func deactivatePatch(_ completion: @escaping (EquilDeactivatePatchResult) -> Void) {
        commandQueue.executeAfterPrimingCancelled { [weak self] in
            guard let self else {
                completion(.failure(error: .unknownError(reason: "Pump manager unavailable")))
                return
            }
            self.deactivatePatchAfterPrimingCancelled(completion: completion)
        }
    }

    private func deactivatePatchAfterPrimingCancelled(completion: @escaping (EquilDeactivatePatchResult) -> Void) {
        guard !state.deviceToken.isEmpty else {
            resetPatchStateAfterDeactivation()
            completion(.success)
            return
        }

        commandQueue.executeCmdOnWorkQueue({
            CmdModelSet(
                mode: RunMode.stop.rawValue,
                createTime: Int64(Date().timeIntervalSince1970 * 1000),
                equilDevice: self.state.deviceToken,
                equilPassword: self.state.password
            )
        }) { result in
            if !result.success {
                completion(.failure(error: .unknownError(reason: result.errorMessage ?? "Deactivation failed")))
                return
            }
            self.resetPatchStateAfterDeactivation()
            self.commandQueue.bleManager.disconnect()
            completion(.success)
        }
    }

    func forceDeactivatePatch() {
        resetPatchStateAfterDeactivation()
        commandQueue.bleManager.disconnect()
    }

    /// Pump removal / unpair REQUIRED sequence:
    ///   1) Retract Plunger (`CmdInsulinChange`) — retract plunger rod,
    ///   2) Stop (`CmdModelSet` stop) — stop delivery on pump (`deactivatePatch` sends),
    ///   3) Unpair/forget — state clear + BLE disconnect (`deactivatePatch` reset; Trio-side
    ///      "forget" in caller completion).
    ///
    /// Retract and stop complete successfully (or error handling) BEFORE unpair.
    /// Retract/stop failure doesn't leave pump half-state: state clear + disconnect
    /// always happens (forceDeactivatePatch fallback), completion reports error.
    func unpairPatchWithSafeSequence(completion: @escaping (Error?) -> Void) {
        syncCommandQueueCredentials()
        commandQueue.bleManager.diagnosticOnly = false
        commandQueue.bleManager.onDiscoverDiagnostic = nil

        guard !state.deviceToken.isEmpty else {
            forceDeactivatePatch()
            clearPairingCredentials()
            completion(nil)
            return
        }

        commandQueue.executeAfterPrimingCancelled { [weak self] in
            guard let self else {
                completion(NSError(domain: "EquilKit", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Pump manager unavailable"
                ]))
                return
            }
            // 1) Retract Plunger — retract plunger BEFORE anything else.
            self.commandQueue.executeCmdOnWorkQueue({
                CmdInsulinChange(
                    createTime: Int64(Date().timeIntervalSince1970 * 1000),
                    equilDevice: self.state.deviceToken,
                    equilPassword: self.state.password
                )
            }, options: EquilCommandQueue.CommandOptions(zeroValueAck: true)) { retractResult in
                let retractError: Error? = retractResult.success ? nil : NSError(
                    domain: "EquilKit",
                    code: -1,
                    userInfo: [
                        NSLocalizedDescriptionKey: retractResult.errorMessage ?? "Retract plunger failed"
                    ]
                )
                if retractResult.success {
                    self.state.isSuspended = true
                    self.state.runMode = .suspend
                    self.state.lastSync = Date.now
                    self.notifyStateDidChange()
                }

                // 2) Stop (CmdModelSet stop) — stop delivery while connection and credentials still live.
                self.commandQueue.executeCmdOnWorkQueue({
                    CmdModelSet(
                        mode: RunMode.stop.rawValue,
                        createTime: Int64(Date().timeIntervalSince1970 * 1000),
                        equilDevice: self.state.deviceToken,
                        equilPassword: self.state.password
                    )
                }) { stopResult in
                    // 3) Unpair (CmdUnPair) — release OLD pump BEFORE clearing state
                    self.sendUnpairCommandTolerantOnWorkQueue {
                        self.resetPatchStateAfterDeactivation()
                        self.clearPairingCredentials()
                        self.commandQueue.bleManager.disconnect()

                        if stopResult.success {
                            completion(retractError)
                        } else {
                            completion(NSError(
                                domain: "EquilKit",
                                code: -1,
                                userInfo: [
                                    NSLocalizedDescriptionKey: "Stop failed during unpair: \(stopResult.errorMessage ?? "unknown")"
                                ]
                            ))
                        }
                    }
                }
            }
        }
    }

    /// Send CmdUnPair to old pump (FAULT-TOLERANT). Standalone calls (not unpair chain).
    private func sendUnpairCommandTolerant(_ completion: @escaping () -> Void) {
        let sn = state.serialNumber
        let pairPwd = state.pairingPassword
        guard !sn.isEmpty, !pairPwd.isEmpty else {
            completion()
            return
        }
        commandQueue.serialNumber = sn
        commandQueue.peripheralUUID = state.peripheralUUID
        commandQueue.executeCmd({
            CmdUnPair(
                name: sn,
                password: pairPwd,
                createTime: Int64(Date().timeIntervalSince1970 * 1000)
            )
        }, options: EquilCommandQueue.CommandOptions(zeroValueAck: true)) { _ in
            completion()
        }
    }

    /// CmdUnPair on workQueue (after unpair chain atomic takeover).
    private func sendUnpairCommandTolerantOnWorkQueue(_ completion: @escaping () -> Void) {
        let sn = state.serialNumber
        let pairPwd = state.pairingPassword
        guard !sn.isEmpty, !pairPwd.isEmpty else {
            completion()
            return
        }
        // Route connect-per-command scan/reconnect to correct pump.
        commandQueue.serialNumber = sn
        commandQueue.peripheralUUID = state.peripheralUUID
        commandQueue.executeCmdOnWorkQueue({
            CmdUnPair(
                name: sn,
                password: pairPwd,
                createTime: Int64(Date().timeIntervalSince1970 * 1000)
            )
        }, options: EquilCommandQueue.CommandOptions(zeroValueAck: true)) { _ in
            completion()
        }
    }

    /// Clear pairing credentials (unpair / pump swap): token + passwords + peripheral,
    /// so old pump data doesn't stick (NEW pairing required). serialNumber handled by
    /// "forget" UI flow; here we clear connection id and secrets.
    private func clearPairingCredentials() {
        state.deviceToken = ""
        state.password = ""
        state.pairingPassword = ""
        state.peripheralUUID = nil
        commandQueue.peripheralUUID = nil
        notifyStateDidChange()
    }

    func updatePatchSettings(completion: @escaping (EquilUpdatePatchResult) -> Void) {
        guard !state.deviceToken.isEmpty else {
            completion(.success)
            return
        }

        state.maxBolus = min(state.maxBolus, state.maxHourlyInsulin)
        state.maxBasal = min(state.maxBasal, state.maxDailyInsulin / 24.0)

        commandQueue.executeCmd({
            CmdSettingSet(
                maxBolus: self.state.maxBolus,
                maxBasal: self.state.maxBasal,
                equilDevice: self.state.deviceToken,
                equilPassword: self.state.password,
                createTime: Int64(Date().timeIntervalSince1970 * 1000)
            )
        }) { result in
            if result.success {
                self.state.lastSync = Date.now
                self.notifyStateDidChange()
                completion(.success)
            } else {
                completion(.failure(error: .unknownError(reason: result.errorMessage ?? "Update failed")))
            }
        }
    }

    private func resetPatchStateAfterDeactivation() {
        let suspendStart = Date.now
        let suspendDose = UnfinalizedDose(suspendStartTime: suspendStart)
        emitPumpEvents([NewPumpEvent.suspend(dose: suspendDose.toDoseEntry())])

        if !state.patchId.isEmpty {
            state.previousPatch = PreviousPatch(
                patchId: state.patchId,
                lastStateRaw: state.pumpState.rawValue,
                lastSyncAt: state.lastSync,
                battery: state.battery,
                activatedAt: state.patchActivatedAt ?? Date.distantPast,
                deactivatedAt: suspendStart,
                initialReservoirLevel: state.initialReservoir,
                reservoirLevel: state.reservoir
            )
        }

        state.patchId = Data()
        state.sessionToken = Data()
        state.pumpState = .none
        state.primeProgress = 0
        state.initialReservoir = nil
        state.basalDose = suspendDose
        state.isSuspended = true
        state.runMode = .stop
        state.lastSync = Date.now
        notifyStateDidChange()
    }
}
