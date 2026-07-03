import Foundation

public enum AlertType: UInt16 {
    case hourly = 4
    case daily = 5
}

public enum ExpiryMode: Int {
    case `default` = 1
    case extended = 2

    var lifespan: TimeInterval {
        switch self {
        case .default:
            return .hours(72)
        case .extended:
            return .hours(112)
        }
    }

    var gracePeriod: TimeInterval {
        .hours(8)
    }

    var timer: UInt8 {
        self == .default ? 1 : 0
    }
}

public struct PreviousPatch: Codable {
    public var patchId: Data
    public var lastStateRaw: UInt8
    public var lastSyncAt: Date
    public var battery: Double
    public var activatedAt: Date
    public var deactivatedAt: Date
    public var initialReservoirLevel: Double?
    public var reservoirLevel: Double?
}
