import Foundation

public protocol CredentialRetention: Sendable {
    func persistOutstanding(_ ids: [String], jobId: JobId) async throws
    func loadOutstanding() async throws -> [(JobId, String)]
}

public actor InMemoryCredentialRetention: CredentialRetention {
    private var rows: [(JobId, String)] = []

    public init() {}

    public func persistOutstanding(_ ids: [String], jobId: JobId) async throws {
        rows.removeAll { $0.0 == jobId }
        rows.append(contentsOf: ids.map { (jobId, $0) })
    }

    public func loadOutstanding() async throws -> [(JobId, String)] {
        rows
    }
}

public actor CredentialManager {
    private let provisioner: any CredentialProvisioner
    private let retention: any CredentialRetention
    private var credentialsByJob: [JobId: [ProvisionedCredential]] = [:]
    private var leaseByJob: [JobId: LeaseSnapshot] = [:]
    private let sessionId: SessionId

    public init(
        provisioner: any CredentialProvisioner,
        retention: any CredentialRetention,
        sessionId: SessionId
    ) {
        self.provisioner = provisioner
        self.retention = retention
        self.sessionId = sessionId
    }

    public var outstandingCredentialIds: [String] {
        credentialsByJob.values.flatMap { $0.map(\.id) }.sorted()
    }

    public func issueForJob(_ jobId: JobId, lease: LeaseSnapshot) async throws
        -> [ProvisionedCredential]
    {
        let credentials = try await provisioner.issue(lease: lease, jobId: jobId, sessionId: sessionId)
        credentialsByJob[jobId] = credentials
        leaseByJob[jobId] = lease
        try await retention.persistOutstanding(credentials.map(\.id), jobId: jobId)
        return credentials
    }

    public func revokeAll(jobId: JobId) async {
        let credentials = credentialsByJob.removeValue(forKey: jobId) ?? []
        leaseByJob.removeValue(forKey: jobId)
        for credential in credentials {
            await revokeWithRetry(credential.id)
        }
        try? await retention.persistOutstanding([], jobId: jobId)
    }

    public func rotate(jobId: JobId, credentialId: String) async throws -> ProvisionedCredential {
        guard let lease = leaseByJob[jobId] else {
            throw ARCPError.notFound(kind: "job credentials", id: jobId.rawValue)
        }
        let next = try await provisioner.issue(lease: lease, jobId: jobId, sessionId: sessionId)
        guard let replacement = next.first else {
            throw ARCPError.unavailable(reason: "credential rotation returned no credential", retryAfter: nil)
        }
        var existing = credentialsByJob[jobId] ?? []
        if let old = existing.first(where: { $0.id == credentialId }) {
            await revokeWithRetry(old.id)
            existing.removeAll { $0.id == credentialId }
        }
        existing.append(replacement)
        credentialsByJob[jobId] = existing
        try await retention.persistOutstanding(existing.map(\.id), jobId: jobId)
        return replacement
    }

    private func revokeWithRetry(_ credentialId: String) async {
        var delay: UInt64 = 100_000_000
        for attempt in 0..<3 {
            do {
                try await provisioner.revoke(credentialId: credentialId)
                return
            } catch where attempt < 2 {
                try? await Task.sleep(nanoseconds: delay)
                delay *= 2
            } catch {
                return
            }
        }
    }
}
