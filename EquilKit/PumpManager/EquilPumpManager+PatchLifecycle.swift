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

    /// Pumpa eltávolítás / unpair KÖTELEZŐ sorrendje:
    ///   1) Retract Plunger (`CmdInsulinChange`) — a dugattyúrúd visszahúzása,
    ///   2) Stop (`CmdModelSet` stop) — adagolás leállítása a pumpán (a `deactivatePatch` küldi),
    ///   3) Unpair/forget — state törlés + BLE bontás (a `deactivatePatch` reset-je; a Trio-oldali
    ///      "forget" a hívó completionjében történik).
    ///
    /// A retract és a stop SIKERESEN lefut (vagy hibakezelés) MIELŐTT az unpair megtörténik.
    /// A retract/stop hibája nem hagyja félállapotban a pumpát: a state törlés + bontás
    /// minden esetben megtörténik (forceDeactivatePatch fallback), a hibát a completion jelzi.
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
            // 1) Retract Plunger — a dugattyú visszahúzása MIELŐTT bármi mást teszünk.
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

                // 2) Stop (CmdModelSet stop) — adagolás leállítása, MÉG él a kapcsolat és a credentials.
                self.commandQueue.executeCmdOnWorkQueue({
                    CmdModelSet(
                        mode: RunMode.stop.rawValue,
                        createTime: Int64(Date().timeIntervalSince1970 * 1000),
                        equilDevice: self.state.deviceToken,
                        equilPassword: self.state.password
                    )
                }) { stopResult in
                    // 3) Unpair (CmdUnPair) — a RÉGI pumpa felszabadítása MIELŐTT a state-et töröljük
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

    /// CmdUnPair elküldése a régi pumpának (HIBATŰRŐ). Standalone hívásokhoz (nem unpair-lánc).
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

    /// CmdUnPair a workQueue-n (unpair lánc atomi takeover után).
    private func sendUnpairCommandTolerantOnWorkQueue(_ completion: @escaping () -> Void) {
        let sn = state.serialNumber
        let pairPwd = state.pairingPassword
        guard !sn.isEmpty, !pairPwd.isEmpty else {
            completion()
            return
        }
        // A megfelelő pumpára irányítjuk a connect-per-command scan/reconnect-et.
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

    /// A párosítási credentials törlése (unpair / pumpacsere): token + jelszavak + peripheral,
    /// hogy a régi pumpa adatai NE ragadjanak be (ÚJ párosítás kelljen). A serialNumber-t a
    /// "forget" UI-folyam kezeli; itt a kapcsolat-azonosítót és a titkokat töröljük.
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
