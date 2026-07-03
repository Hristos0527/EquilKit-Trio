import Foundation
import LoopKit

public extension EquilPumpManager {
    var alarmMode: AlarmMode {
        AlarmMode.fromInt(state.alarmModeRaw)
    }

    /// Sets pump sound/vibration mode via CmdAlarmSet (persists on the pump firmware).
    /// A FELHASZNÁLÓI beállítás (Patch Settings) ezt hívja → `persist: true`: a választott
    /// módot tartósan elmentjük `state.alarmModeRaw`-ba (ez a user perzisztens preferenciája).
    func setAlarmMode(_ mode: AlarmMode, completion: @escaping (Result<Void, Error>) -> Void) {
        setAlarmMode(mode, persist: true, completion: completion)
    }

    /// Belső változat a `persist` kapcsolóval. Az ÁTMENETI MUTE (suspend/zero-temp idejére) ezt
    /// `persist: false`-szal hívja: a parancsot a pumpára küldi, de a user perzisztens
    /// alarm-beállítását (`state.alarmModeRaw`) NEM írja felül. Így a resume-nál a TÉNYLEGES,
    /// user által választott módot tudjuk visszaállítani (nem egy átmeneti mute-ot vagy defaultot).
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
                // CSAK perzisztens kérésnél írjuk felül a user-preferenciát. Átmeneti mute-nál
                // (persist:false) a user perzisztens módja érintetlen marad.
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
