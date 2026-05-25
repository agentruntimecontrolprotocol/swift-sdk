import Foundation

/// Server-side credential validator. RFC §8.2.
///
/// The runtime hands an `AuthBlock` to `validate` along with an optional
/// challenge nonce. The validator returns the authenticated principal on
/// success or throws `ARCPError.unauthenticated` / `.unimplemented` on failure.
public protocol AuthValidator: Sendable {
    /// Whether this validator supports the given scheme.
    func supports(_ scheme: AuthScheme) -> Bool

    /// Validate the credential block. Returns the authenticated principal.
    func validate(auth: AuthBlock, challenge nonce: String?) async throws -> AuthenticatedPrincipal
}

/// Result of successful credential validation.
public struct AuthenticatedPrincipal: Sendable, Hashable {
    /// Subject (`sub`) identifier of the authenticated principal.
    public var subject: String
    /// Trust level granted to the principal by the validator.
    public var trustLevel: TrustLevel

    /// Create an authenticated principal.
    public init(subject: String, trustLevel: TrustLevel = .trusted) {
        self.subject = subject
        self.trustLevel = trustLevel
    }
}

/// Composite validator that fans out to scheme-specific validators.
public struct CompositeAuthValidator: AuthValidator {
    /// Validators that this composite fans out to in order.
    public let validators: [any AuthValidator]

    /// Wrap a list of scheme-specific validators behind a single facade.
    public init(_ validators: [any AuthValidator]) {
        self.validators = validators
    }

    /// Return `true` if any wrapped validator supports `scheme`.
    public func supports(_ scheme: AuthScheme) -> Bool {
        validators.contains { $0.supports(scheme) }
    }

    /// Validate `auth` against the first wrapped validator that supports its scheme.
    public func validate(
        auth: AuthBlock,
        challenge nonce: String?
    ) async throws -> AuthenticatedPrincipal {
        for validator in validators where validator.supports(auth.scheme) {
            return try await validator.validate(auth: auth, challenge: nonce)
        }
        switch auth.scheme {
        case .mtls, .oauth2:
            throw ARCPError.unimplemented(
                section: "§8.2",
                detail: "auth scheme \(auth.scheme.rawValue) is out of scope for v0.1"
            )
        default:
            throw ARCPError.unauthenticated(
                detail: "no validator supports scheme \(auth.scheme.rawValue)"
            )
        }
    }
}
