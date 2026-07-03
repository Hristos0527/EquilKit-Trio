import Foundation
import LoopKit

final class EquilSettingsBluetooth {
    private let commandQueue: EquilCommandQueue

    init(commandQueue: EquilCommandQueue) {
        self.commandQueue = commandQueue
    }

    var isConnected: Bool { commandQueue.bleManager.isConnected }

    func disconnect(force _: Bool) {
        commandQueue.bleManager.disconnect()
    }

    func clearPeripheral() {
        commandQueue.bleManager.disconnect()
    }

    func ensureConnected(_ completion: @escaping (Error?) -> Void) {
        if commandQueue.bleManager.isConnected {
            completion(nil)
            return
        }
        commandQueue.bleManager.connectForCommand()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else {
                completion(NSError(domain: "EquilKit", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "BLE connection failed"
                ]))
                return
            }
            completion(self.isConnected ? nil : NSError(domain: "EquilKit", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "BLE connection failed"
            ]))
        }
    }
}

extension EquilPumpManager {
    var bluetooth: EquilSettingsBluetooth {
        EquilSettingsBluetooth(commandQueue: commandQueue)
    }

    func syncPumpData(completion: ((Date?) -> Void)?) {
        ensureCurrentPumpData(completion: completion)
    }

    func syncPumpTime(completion: (() -> Void)? = nil) {
        let cmd = CmdTimeSet(
            createTime: Int64(Date().timeIntervalSince1970 * 1000),
            equilDevice: state.deviceToken,
            equilPassword: state.password
        )
        commandQueue.executeCmd({ cmd }) { [weak self] result in
            guard let self else {
                completion?()
                return
            }
            if result.success {
                self.state.lastSync = Date.now
                self.notifyStateDidChange()
            }
            completion?()
        }
    }

    func suspendPatch(duration _: TimeInterval, completion: @escaping ((any Error)?) -> Void) {
        suspendDelivery(completion: completion)
    }

    func clearAlert(alertType _: AlertType, completion: @escaping ((any Error)?) -> Void) {
        completion(nil)
    }

    /// Single manual prime step (`CmdStepSet`, `EQUIL_STEP_MANUAL` = 80 steps) without auto resistance loop.
    func primeOneStep(completion: @escaping (Result<Void, Error>) -> Void) {
        guard !state.deviceToken.isEmpty else {
            completion(.failure(NSError(domain: "EquilKit", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Pump not paired"
            ])))
            return
        }

        let cmd = CmdStepSet(
            sendConfig: false,
            step: EquilConst.EQUIL_STEP_MANUAL,
            createTime: Int64(Date().timeIntervalSince1970 * 1000),
            equilDevice: state.deviceToken,
            equilPassword: state.password
        )
        commandQueue.executeCmd({ cmd }) { [weak self] result in
            guard let self else {
                completion(.failure(NSError(domain: "EquilKit", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Pump manager unavailable"
                ])))
                return
            }
            if result.success {
                self.state.lastSync = Date.now
                self.notifyStateDidChange()
                completion(.success(()))
            } else {
                completion(.failure(NSError(domain: "EquilKit", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: result.errorMessage ?? "Prime step failed"
                ])))
            }
        }
    }

    /// Retract plunger for reservoir change (`CmdInsulinChange`, step 32000).
    func retractPlungerForReservoirChange(completion: @escaping (Error?) -> Void) {
        guard !state.deviceToken.isEmpty else {
            completion(NSError(domain: "EquilKit", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Pump not paired"
            ]))
            return
        }

        commandQueue.executeCmd({
            CmdInsulinChange(
                createTime: Int64(Date().timeIntervalSince1970 * 1000),
                equilDevice: self.state.deviceToken,
                equilPassword: self.state.password
            )
        }, options: EquilCommandQueue.CommandOptions(zeroValueAck: true)) { [weak self] result in
            guard let self else {
                completion(NSError(domain: "EquilKit", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Pump manager unavailable"
                ]))
                return
            }
            if result.success {
                self.state.isSuspended = true
                self.state.runMode = .suspend
                self.state.lastSync = Date.now
                self.notifyStateDidChange()
                completion(nil)
            } else {
                completion(NSError(domain: "EquilKit", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: result.errorMessage ?? "Retract plunger failed"
                ]))
            }
        }
    }
}
