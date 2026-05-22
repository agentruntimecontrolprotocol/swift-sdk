import Foundation
import Testing

@testable import ARCP

@Suite("Provisioned credentials (ARCP v1.1 §9.8)")
struct CredentialMessagesTests {
    @Test("ProvisionedCredential Codable round-trip")
    func credentialRoundTrip() throws {
        let credential = try ProvisionedCredential(
            id: "cred_1",
            scheme: .bearer,
            value: "secret-token",
            endpoint: "https://gateway.example",
            profile: "fast",
            constraints: CredentialConstraints(
                costBudget: .from(["USD": 5]),
                modelUse: ModelUse(patterns: ["tier-fast/*"]),
                expiresAt: Date(timeIntervalSince1970: 1_800)
            )
        )
        let encoded = try JSONEncoder().encode(credential)
        let decoded = try JSONDecoder().decode(ProvisionedCredential.self, from: encoded)
        #expect(decoded == credential)
    }

    @Test("ProvisionedCredential redacts value in description")
    func descriptionRedactsValue() throws {
        let credential = try ProvisionedCredential(
            id: "cred_1",
            scheme: .bearer,
            value: "do-not-print",
            endpoint: "https://gateway.example"
        )
        #expect(!String(describing: credential).contains("do-not-print"))
        #expect(String(describing: credential).contains("<redacted>"))
    }

    @Test("CredentialConstraints encodes dotted wire keys")
    func constraintsUseDottedKeys() throws {
        let constraints = CredentialConstraints(
            costBudget: .from(["USD": 1]),
            modelUse: ModelUse(patterns: ["m/*"]),
            expiresAt: Date(timeIntervalSince1970: 1)
        )
        let data = try JSONEncoder().encode(constraints)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["cost.budget"] != nil)
        #expect(object["model.use"] != nil)
        #expect(object["expires_at"] != nil)
    }

    @Test("JobAcceptedPayload encodes credentials field when present")
    func jobAcceptedCarriesCredentials() throws {
        let credential = try ProvisionedCredential(
            id: "cred_1",
            scheme: .bearer,
            value: "secret",
            endpoint: "https://gateway.example"
        )
        let payload = JobAcceptedPayload(jobId: JobId("job_1"), credentials: [credential])
        let data = try JSONEncoder().encode(payload)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["job_id"] as? String == "job_1")
        #expect(object["credentials"] != nil)
    }
}
