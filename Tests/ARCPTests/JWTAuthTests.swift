import Foundation
import JWTKit
import Testing

@testable import ARCP

@Suite("JWT challenge binding (issue #58)")
struct JWTAuthTests {
    @Test("Validator rejects token without nonce when challenge present")
    func rejectsMissingNonce() async throws {
        let keys = JWTKeyCollection()
        await keys.add(hmac: HMACKey(stringLiteral: "super-secret"), digestAlgorithm: .sha256)

        let validator = JWTAuthValidator(keys: keys, audience: "arcp")
        let signed = try await keys.sign(
            JWTPayloadFixture(
                sub: "alice",
                aud: "arcp",
                exp: Date().addingTimeInterval(60),
                nonce: nil
            )
        )
        await #expect(throws: ARCPError.self) {
            _ = try await validator.validate(
                auth: AuthBlock(scheme: .signedJwt, token: signed),
                challenge: "nonce-123"
            )
        }
    }

    @Test("Validator rejects mismatched nonce")
    func rejectsWrongNonce() async throws {
        let keys = JWTKeyCollection()
        await keys.add(hmac: HMACKey(stringLiteral: "super-secret"), digestAlgorithm: .sha256)
        let validator = JWTAuthValidator(keys: keys, audience: "arcp")
        let signed = try await keys.sign(
            JWTPayloadFixture(
                sub: "alice",
                aud: "arcp",
                exp: Date().addingTimeInterval(60),
                nonce: "wrong"
            )
        )
        await #expect(throws: ARCPError.self) {
            _ = try await validator.validate(
                auth: AuthBlock(scheme: .signedJwt, token: signed),
                challenge: "correct"
            )
        }
    }

    @Test("Validator accepts matching nonce")
    func acceptsMatchingNonce() async throws {
        let keys = JWTKeyCollection()
        await keys.add(hmac: HMACKey(stringLiteral: "super-secret"), digestAlgorithm: .sha256)
        let validator = JWTAuthValidator(keys: keys, audience: "arcp")
        let signed = try await keys.sign(
            JWTPayloadFixture(
                sub: "alice",
                aud: "arcp",
                exp: Date().addingTimeInterval(60),
                nonce: "n-123"
            )
        )
        let principal = try await validator.validate(
            auth: AuthBlock(scheme: .signedJwt, token: signed),
            challenge: "n-123"
        )
        #expect(principal.subject == "alice")
    }

    @Test("Validator accepts token without nonce when no challenge issued")
    func acceptsAbsentChallenge() async throws {
        let keys = JWTKeyCollection()
        await keys.add(hmac: HMACKey(stringLiteral: "super-secret"), digestAlgorithm: .sha256)
        let validator = JWTAuthValidator(keys: keys, audience: "arcp")
        let signed = try await keys.sign(
            JWTPayloadFixture(
                sub: "bob",
                aud: "arcp",
                exp: Date().addingTimeInterval(60),
                nonce: nil
            )
        )
        let principal = try await validator.validate(
            auth: AuthBlock(scheme: .signedJwt, token: signed),
            challenge: nil
        )
        #expect(principal.subject == "bob")
    }
}

private struct JWTPayloadFixture: JWTPayload {
    var sub: SubjectClaim
    var aud: AudienceClaim
    var exp: ExpirationClaim
    var nonce: String?

    init(sub: String, aud: String, exp: Date, nonce: String?) {
        self.sub = SubjectClaim(value: sub)
        self.aud = AudienceClaim(value: aud)
        self.exp = ExpirationClaim(value: exp)
        self.nonce = nonce
    }

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired()
    }
}
