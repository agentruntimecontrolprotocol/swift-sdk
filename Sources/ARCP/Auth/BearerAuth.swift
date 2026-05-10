/// Static bearer-token validator backed by an in-memory map of token →
/// principal. Production deployments should provide a custom `AuthValidator`
/// that hits the real trust store.
public struct BearerAuthValidator: AuthValidator {
    private let principals: [String: AuthenticatedPrincipal]

    public init(_ principals: [String: AuthenticatedPrincipal]) {
        self.principals = principals
    }

    /// Convenience initializer mapping token → subject string.
    public init(subjectsByToken: [String: String], trustLevel: TrustLevel = .trusted) {
        var map: [String: AuthenticatedPrincipal] = [:]
        for (token, subject) in subjectsByToken {
            map[token] = AuthenticatedPrincipal(subject: subject, trustLevel: trustLevel)
        }
        self.principals = map
    }

    public func supports(_ scheme: AuthScheme) -> Bool {
        scheme == .bearer
    }

    public func validate(
        auth: AuthBlock,
        challenge nonce: String?
    ) async throws -> AuthenticatedPrincipal {
        guard auth.scheme == .bearer else {
            throw ARCPError.unauthenticated(
                detail: "BearerAuthValidator does not support \(auth.scheme.rawValue)"
            )
        }
        guard let token = auth.token, !token.isEmpty else {
            throw ARCPError.unauthenticated(detail: "bearer token missing")
        }
        guard let principal = principals[token] else {
            throw ARCPError.unauthenticated(detail: "bearer token not recognized")
        }
        return principal
    }
}
