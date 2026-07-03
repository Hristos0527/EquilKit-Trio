import Foundation
import LoopKit

public extension EquilPumpManager {
    var alarmMode: AlarmMode {
        AlarmMode.fromInt(state.alarmModeRaw)
    }

    /// Sets pump sound/vibration mode via CmdAlarmSet (persists on the pump firmware).
    /// USER setting (Patch Settings) calls this → `persist: true`: chosen
    /// mode is permanently saved to `state.alarmModeRaw` (user persistent preference).
    func setAlarmMode(_ mode: AlarmMode, completion: @escaping (Result<Void, Error>) -> Void) {
        setAlarmMode(mode, persist: true, completion: completion)
    }

    /// Internal variant with `persist` switch. TEMPORARY MUTE (during suspend/zero-temp) calls this
    /// with `persist: false`: sends command to pump but does NOT overwrite user persistent
    /// alarm setting (`state.alarmModeRaw`). On resume we restore the ACTUAL
    /// user-chosen mode (not a temporary mute or default).
    func setAlarmMode(
        _ mode: AlarmMode,
        persist: Bool,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard !state.deviceToken.isEmpty else {
            completion(.failure(NSError(domain: "EquilKit", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Pump not paired"
            ])))
            return
        }

        let cmd = CmdAlarmSet(
            mode: mode.rawValue,
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
                // ONLY overwrite user preference on persistent request. Temporary mute
                // (persist:false) leaves user persistent mode untouched.
                if persist {
                    self.state.alarmModeRaw = mode.rawValue
                    self.state.userExplicitAlarmMode = true
                }
                self.state.lastSync = Date.now
                self.notifyStateDidChange()
                completion(.success(()))
            } else {
                completion(.failure(NSError(domain: "EquilKit", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: result.errorMessage ?? "Failed to set alert mode"
                ])))
            }
        }
    }
}
