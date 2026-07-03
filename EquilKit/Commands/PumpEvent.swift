import Foundation

struct PumpEvent: Hashable {
    let port: Int
    let type: Int
    let level: Int
    let comment: String

    static func == (lhs: PumpEvent, rhs: PumpEvent) -> Bool {
        lhs.port == rhs.port && lhs.type == rhs.type && lhs.level == rhs.level
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(port)
        hasher.combine(type)
        hasher.combine(level)
    }

    private static var lists: [PumpEvent] = []

    static func registerDefaults() {
        lists = [
            PumpEvent(port: 4, type: 0, level: 0, comment: "--"),
            PumpEvent(port: 4, type: 1, level: 1, comment: "Bolus delivery"),
            PumpEvent(port: 4, type: 1, level: 2, comment: "Bolus cancelled"),
            PumpEvent(port: 4, type: 2, level: 2, comment: "Temporary basal"),
            PumpEvent(port: 4, type: 3, level: 0, comment: "Extended bolus"),
            PumpEvent(port: 4, type: 3, level: 2, comment: "Extended bolus cancelled"),
            PumpEvent(port: 4, type: 5, level: 0, comment: "Basal profile"),
            PumpEvent(port: 4, type: 5, level: 1, comment: "Basal profile updated"),
            PumpEvent(port: 4, type: 6, level: 1, comment: "Alarm mute"),
            PumpEvent(port: 4, type: 6, level: 2, comment: "Alarm tone/shake"),
            PumpEvent(port: 4, type: 7, level: 0, comment: "Insulin change"),
            PumpEvent(port: 4, type: 8, level: 0, comment: "Time set"),
            PumpEvent(port: 4, type: 9, level: 0, comment: "Suspend"),
            PumpEvent(port: 4, type: 10, level: 0, comment: "Resume"),
            PumpEvent(port: 4, type: 11, level: 0, comment: "Unpair"),
            PumpEvent(port: 5, type: 0, level: 1, comment: "Low insulin"),
            PumpEvent(port: 5, type: 0, level: 2, comment: "Low insulin warning"),
            PumpEvent(port: 5, type: 1, level: 0, comment: "Occlusion"),
            PumpEvent(port: 5, type: 1, level: 2, comment: "Occlusion cleared")
        ]
    }

    static func getTips(port: Int, type: Int, level: Int) -> String {
        if lists.isEmpty { registerDefaults() }
        let key = PumpEvent(port: port, type: type, level: level, comment: "")
        guard let index = lists.firstIndex(of: key) else { return "" }
        return lists[index].comment
    }
}
