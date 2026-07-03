public enum EquilPrimePatchResult {
    case success
    case failure(error: EquilPrimePatchError)
}

public enum EquilPrimePatchError: LocalizedError {
    case needToDeactivateFirst
    case connectionFailure(reason: String)
    case noKnownPumpBase
    case unknownError(reason: LocalizedError)

    var description: String {
        switch self {
        case let .connectionFailure(reason: reason):
            return "Failed to connect to pump base: \(reason)"
        case .needToDeactivateFirst:
            return "Pump base is currently active. Please deactivate it first."
        case .noKnownPumpBase:
            return "No known pump base found."
        case let .unknownError(reason: reason):
            return "Unknown error: \(reason)"
        }
    }
}
