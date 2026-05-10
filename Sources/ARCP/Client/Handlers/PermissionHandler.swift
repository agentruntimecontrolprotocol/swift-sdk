/// Client-side permission challenge handler. RFC §15.4.
public protocol PermissionHandler: Sendable {
    /// Decide whether to grant a permission challenge. Return `.granted(seconds:)`
    /// to issue a lease for that duration, or `.denied(reason:)` to refuse.
    func handle(_ request: PermissionRequestPayload, jobId: JobId?) async throws -> Decision

    /// Outcome the handler returns for a request.
    typealias Decision = PermissionDecision
}

public enum PermissionDecision: Sendable, Equatable {
    case granted(seconds: Int)
    case denied(reason: String)
}

/// Default deny-all handler. Replace in production deployments.
public struct DefaultPermissionHandler: PermissionHandler {
    public init() {}

    public func handle(_ request: PermissionRequestPayload, jobId: JobId?) async throws -> Decision {
        .denied(reason: "no PermissionHandler registered")
    }
}
