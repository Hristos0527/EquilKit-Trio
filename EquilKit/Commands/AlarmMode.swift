import Foundation

/// Equil pump alert mode (AndroidAPS AlarmMode, CmdAlarmSet payload).
public enum AlarmMode: Int, CaseIterable, Identifiable {
    case mute = 0
    case tone = 1
    case shake = 2
    case toneAndShake = 3

    public var id: Int { rawValue }

    public var command: Int { rawValue }

    /// Dashboard picker: sound, vibration, silent (user patch).
    public static var dashboardOptions: [AlarmMode] {
        [.tone, .shake, .mute]
    }

    public var label: String {
        switch self {
        case .mute:
            return String(localized: "Silent", comment: "Equil alert mode: no sound or vibration")
        case .tone:
            return String(localized: "Sound", comment: "Equil alert mode: beep only")
        case .shake:
            return String(localized: "Vibration", comment: "Equil alert mode: vibration only")
        case .toneAndShake:
            return String(localized: "Sound + Vibration", comment: "Equil alert mode: beep and vibration")
        }
    }

    public static func fromInt(_ number: Int) -> AlarmMode {
        AlarmMode(rawValue: number) ?? .tone
    }
}
