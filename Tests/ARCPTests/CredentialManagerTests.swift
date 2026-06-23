import Foundation
import Testing

@testable import ARCP

@Suite("CredentialManager rotation")
struct CredentialManagerTests {
    @Test("rotate persists every credential returned by provisioner")
    func rotateKeepsFullReturnedSet() async throws {
        let provisioner = SequenceCredentialProvisioner([
            [
                try credential("old_access"),
                try credential("old_refresh"),
            ],
            [
                try credential("new_access"),
                try credential("new_refresh"),
            ],
        ])
        let retention = InMemoryCredentialRetention()
        let manager = CredentialManager(
            provisioner: provisioner,
            retention: retention,
            sessionId: SessionId("sess_credentials")
        )
        let jobId = JobId("job_credentials")
        _ = try await manager.issueForJob(jobId, lease: LeaseSnapshot(expiresAt: Date()))

        let replacement = try await manager.rotate(jobId: jobId, credentialId: "old_access")

        #expect(replacement.id == "new_access")
        #expect(
            await manager.outstandingCredentialIds == [
                "new_access",
                "new_refresh",
                "old_refresh",
            ])
        #expect(
            try await retention.loadOutstanding().map(\.1).sorted() == [
                "new_access",
                "new_refresh",
                "old_refresh",
            ])
        #expect(await provisioner.revoked == ["old_access"])
    }

    @Test("rotate can return an in-place replacement from later in returned array")
    func rotateReturnsMatchingReplacementWhenPresent() async throws {
        let provisioner = SequenceCredentialProvisioner([
            [try credential("old_access")],
            [
                try credential("paired"),
                try credential("old_access"),
            ],
        ])
        let manager = CredentialManager(
            provisioner: provisioner,
            retention: InMemoryCredentialRetention(),
            sessionId: SessionId("sess_credentials")
        )
        let jobId = JobId("job_credentials")
        _ = try await manager.issueForJob(jobId, lease: LeaseSnapshot(expiresAt: Date()))

        let replacement = try await manager.rotate(jobId: jobId, credentialId: "old_access")

        #expect(replacement.id == "old_access")
        #expect(await manager.outstandingCredentialIds == ["old_access", "paired"])
    }

    private func credential(_ id: String) throws -> ProvisionedCredential {
        try ProvisionedCredential(
            id: id,
            scheme: .bearer,
            value: "value-\(id)",
            endpoint: "https://credentials.example.test"
        )
    }
}

private actor SequenceCredentialProvisioner: CredentialProvisioner {
    private var batches: [[ProvisionedCredential]]
    private(set) var revoked: [String] = []

    init(_ batches: [[ProvisionedCredential]]) {
        self.batches = batches
    }

    func issue(
        lease: LeaseSnapshot,
        jobId: JobId,
        sessionId: SessionId
    ) async throws -> [ProvisionedCredential] {
        guard !batches.isEmpty else { return [] }
        return batches.removeFirst()
    }

    func revoke(credentialId: String) async throws {
        revoked.append(credentialId)
    }
}
