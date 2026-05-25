import Foundation
import Testing

@testable import ARCP

@Suite("Auth validators")
struct AuthTests {
    @Test("Bearer validator maps tokens to principals")
    func bearerHappyPath() async throws {
        let validator = BearerAuthValidator(subjectsByToken: ["token": "alice"], trustLevel: .untrusted)
        #expect(validator.supports(.bearer))
        let principal = try await validator.validate(
            auth: AuthBlock(scheme: .bearer, token: "token"),
            challenge: nil
        )
        #expect(principal == AuthenticatedPrincipal(subject: "alice", trustLevel: .untrusted))
    }

    @Test("Bearer validator rejects wrong scheme, missing token, and unknown token")
    func bearerFailures() async {
        let validator = BearerAuthValidator(subjectsByToken: ["token": "alice"])
        await #expect(throws: ARCPError.self) {
            _ = try await validator.validate(auth: AuthBlock(scheme: .none), challenge: nil)
        }
        await #expect(throws: ARCPError.self) {
            _ = try await validator.validate(auth: AuthBlock(scheme: .bearer), challenge: nil)
        }
        await #expect(throws: ARCPError.self) {
            _ = try await validator.validate(
                auth: AuthBlock(scheme: .bearer, token: "wrong"),
                challenge: nil
            )
        }
    }

    @Test("Composite validator dispatches by scheme and reports unsupported schemes")
    func compositeValidator() async throws {
        let bearer = BearerAuthValidator([
            "token": AuthenticatedPrincipal(subject: "alice", trustLevel: .trusted)
        ])
        let composite = CompositeAuthValidator([bearer])
        #expect(composite.supports(.bearer))
        #expect(!composite.supports(.signedJwt))

        let principal = try await composite.validate(
            auth: AuthBlock(scheme: .bearer, token: "token"),
            challenge: nil
        )
        #expect(principal.subject == "alice")

        await #expect(throws: ARCPError.self) {
            _ = try await composite.validate(auth: AuthBlock(scheme: .signedJwt), challenge: nil)
        }
        await #expect(throws: ARCPError.self) {
            _ = try await composite.validate(auth: AuthBlock(scheme: .mtls), challenge: nil)
        }
    }
}
