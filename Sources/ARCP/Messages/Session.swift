import Foundation

/// `session.open` payload. RFC §8.1.
public struct SessionOpenPayload: Sendable, Codable, Hashable {
    public var auth: AuthBlock
    public var client: IdentityBlock
    public var capabilities: Capabilities

    public init(auth: AuthBlock, client: IdentityBlock, capabilities: Capabilities) {
        self.auth = auth
        self.client = client
        self.capabilities = capabilities
    }
}

/// `session.challenge` payload. RFC §8.1.
public struct SessionChallengePayload: Sendable, Codable, Hashable {
    public var nonce: String
    public var scheme: AuthScheme
    public var expiresAt: Date

    public init(nonce: String, scheme: AuthScheme, expiresAt: Date) {
        self.nonce = nonce
        self.scheme = scheme
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case nonce, scheme
        case expiresAt = "expires_at"
    }
}

/// `session.authenticate` payload. RFC §8.1.
public struct SessionAuthenticatePayload: Sendable, Codable, Hashable {
    public var auth: AuthBlock
    public var nonce: String?

    public init(auth: AuthBlock, nonce: String? = nil) {
        self.auth = auth
        self.nonce = nonce
    }
}

/// `session.accepted` payload. RFC §8.3.
public struct SessionAcceptedPayload: Sendable, Codable, Hashable {
    public var sessionId: SessionId
    public var runtime: IdentityBlock
    public var capabilities: Capabilities
    public var lease: SessionLease?

    public init(
        sessionId: SessionId,
        runtime: IdentityBlock,
        capabilities: Capabilities,
        lease: SessionLease? = nil
    ) {
        self.sessionId = sessionId
        self.runtime = runtime
        self.capabilities = capabilities
        self.lease = lease
    }

    public struct SessionLease: Sendable, Codable, Hashable {
        public var expiresAt: Date

        public init(expiresAt: Date) { self.expiresAt = expiresAt }

        enum CodingKeys: String, CodingKey {
            case expiresAt = "expires_at"
        }
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case runtime, capabilities, lease
    }
}

/// `session.unauthenticated` payload. RFC §8.
public struct SessionUnauthenticatedPayload: Sendable, Codable, Hashable {
    public var detail: String

    public init(detail: String) { self.detail = detail }
}

/// `session.rejected` payload. RFC §8.1.
public struct SessionRejectedPayload: Sendable, Codable, Hashable {
    public var error: ErrorEnvelope

    public init(error: ErrorEnvelope) { self.error = error }
}

/// `session.refresh` payload. RFC §8.4.
public struct SessionRefreshPayload: Sendable, Codable, Hashable {
    public var deadlineMs: Int

    public init(deadlineMs: Int) { self.deadlineMs = deadlineMs }

    enum CodingKeys: String, CodingKey {
        case deadlineMs = "deadline_ms"
    }
}

/// `session.evicted` payload. RFC §8.5.
public struct SessionEvictedPayload: Sendable, Codable, Hashable {
    public var reason: String
    public var code: ErrorCode

    public init(reason: String, code: ErrorCode) {
        self.reason = reason
        self.code = code
    }
}

/// `session.close` payload. RFC §9.
public struct SessionClosePayload: Sendable, Codable, Hashable {
    public var reason: String?

    public init(reason: String? = nil) { self.reason = reason }
}
