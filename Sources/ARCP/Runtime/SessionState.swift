import Foundation

/// Server-side session state machine. RFC §8.1.
///
/// Modeled as an enum with associated values so the compiler enforces that
/// every transition maps a known state to a known state. Out-of-handshake
/// messages received in `.opening` / `.challenged` / `.authenticating` are
/// dropped per RFC §8.1 ("Runtimes MUST drop and log other messages received
/// before acceptance").
public enum SessionState: Sendable, Hashable {
    case opening
    case challenged(nonce: String, scheme: AuthScheme)
    case authenticating
    case accepted(SessionId, AuthenticatedPrincipal)
    case rejected(code: ErrorCode, message: String)
    case evicted(reason: String, code: ErrorCode)
    case closed

    /// True once the four-step handshake has completed successfully.
    public var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }

    /// True once the session is in any terminal state.
    public var isTerminal: Bool {
        switch self {
        case .rejected, .evicted, .closed: return true
        default: return false
        }
    }
}

/// Negotiated capabilities and identities once a session is open. Snapshot
/// returned to clients after `session.accepted`.
public struct SessionInfo: Sendable, Hashable {
    public var sessionId: SessionId
    public var principal: AuthenticatedPrincipal
    public var clientIdentity: IdentityBlock
    public var runtimeIdentity: IdentityBlock
    public var negotiatedCapabilities: Capabilities
    public var openedAt: Date

    public init(
        sessionId: SessionId,
        principal: AuthenticatedPrincipal,
        clientIdentity: IdentityBlock,
        runtimeIdentity: IdentityBlock,
        negotiatedCapabilities: Capabilities,
        openedAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.principal = principal
        self.clientIdentity = clientIdentity
        self.runtimeIdentity = runtimeIdentity
        self.negotiatedCapabilities = negotiatedCapabilities
        self.openedAt = openedAt
    }
}
