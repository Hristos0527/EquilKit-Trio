public enum EquilUpdatePatchResult {
    case success
    case failure(error: EquilUpdatePatchError)
}

public enum EquilUpdatePatchError: LocalizedError {
    case connectionFailure
    case unknownError(reason: String)
}
