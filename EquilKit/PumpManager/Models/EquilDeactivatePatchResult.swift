public enum EquilDeactivatePatchResult {
    case success
    case failure(error: EquilDeactivatePatchError)
}

public enum EquilDeactivatePatchError: LocalizedError {
    case connectionFailure
    case unknownError(reason: String)
}
