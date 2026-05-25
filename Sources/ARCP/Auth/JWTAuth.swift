import Foundation
import JWTKit

/// `signed_jwt` validator. RFC §8.2.
///
/// Validates the JWT's signature against the configured key collection,
/// asserts `aud` matches the runtime identity, and — when the runtime
/// issued a challenge nonce — requires the JWT to carry the same nonce
/// (claim `nonce`). The nonce binding prevents a captured token from being
/// replayed against a fresh challenge until it expires. When no nonce is
/// supplied (no challenge was issued), the JWT need not carry one.
public struct JWTAuthValidator: AuthValidator {
    private let keys: JWTKeyCollection
    private let audience: String
    private let trustLevel: TrustLevel

    public init(keys: JWTKeyCollection, audience: String, trustLevel: TrustLevel = .trusted) {
        self.keys = keys
        self.audience = audience
        self.trustLevel = trustLevel
    }

    /// Return `true` when the validator can handle the supplied scheme.
    ///
    /// - Parameter scheme: Auth scheme advertised by the peer.
    /// - Returns: `true` for `signed_jwt`.
    public func supports(_ scheme: AuthScheme) -> Bool {
        scheme == .signedJwt
    }

    /// Validate a `signed_jwt` credential and return the authenticated principal.
    ///
    /// - Parameters:
    ///   - auth: Authentication block received during the handshake.
    ///   - nonce: Optional challenge nonce from the runtime. When supplied,
    ///     the JWT MUST carry a matching `nonce` claim or the token is
    ///     rejected with `ARCPError.unauthenticated`.
    /// - Returns: The authenticated principal.
    /// - Throws: `ARCPError.unauthenticated` when the token is missing or invalid.
    public func validate(
        auth: AuthBlock,
        challenge nonce: String?
    ) async throws -> AuthenticatedPrincipal {
        guard auth.scheme == .signedJwt else {
            throw ARCPError.unauthenticated(detail: "JWTAuthValidator only supports signed_jwt")
        }
        guard let token = auth.token else {
            throw ARCPError.unauthenticated(detail: "signed_jwt token missing")
        }
        do {
            let payload = try await keys.verify(token, as: ARCPClaims.self)
            try payload.aud.verifyIntendedAudience(includes: audience)
            if let nonce {
                guard let tokenNonce = payload.nonce, !tokenNonce.isEmpty else {
                    throw ARCPError.unauthenticated(
                        detail: "challenge required but JWT carries no nonce claim"
                    )
                }
                guard tokenNonce == nonce else {
                    throw ARCPError.unauthenticated(detail: "JWT nonce does not match challenge")
                }
            }
            return AuthenticatedPrincipal(subject: payload.sub.value, trustLevel: trustLevel)
        } catch let error as ARCPError {
            throw error
        } catch {
            throw ARCPError.unauthenticated(detail: "JWT validation failed: \(error)")
        }
    }
}

/// Minimal claim set used by ARCP JWTs. Deployments are free to issue richer
/// JWTs; only the standard fields plus the optional `nonce` (used for
/// challenge binding) and `jti` (replay-tracking identifier) are inspected
/// here.
struct ARCPClaims: JWTPayload {
    var sub: SubjectClaim
    var aud: AudienceClaim
    var exp: ExpirationClaim
    var iat: IssuedAtClaim?
    var iss: IssuerClaim?
    var nonce: String?
    var jti: String?

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired()
    }
}
