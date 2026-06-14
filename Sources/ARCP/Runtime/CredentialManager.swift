import Foundation
import Logging

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
    private let log: Logger

    public init(
        provisioner: any CredentialProvisioner,
        retention: any CredentialRetention,
        sessionId: SessionId
    ) {
        self.provisioner = provisioner
        self.retention = retention
        self.sessionId = sessionId
        self.log = Logger(label: "arcp.credentials.\(sessionId)")
    }

    public var outstandingCredentialIds: [String] {
        credentialsByJob.values.flatMap { $0.map(\.id) }.sorted()
    }

    public func issueForJob(
        _ jobId: JobId, lease: LeaseSnapshot
    ) async throws
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
            await revokeWithRetry(credential.id, jobId: jobId)
        }
        try? await retention.persistOutstanding([], jobId: jobId)
    }

    /// Rotate the credential identified by `credentialId` for `jobId`.
    ///
    /// The `CredentialProvisioner` contract is treated as returning the full
    /// credential set for the lease (a provider may mint multiple paired
    /// credentials per issuance — e.g. access + refresh token, or several
    /// vendor credentials in a single transactional issue). The rotation
    /// flow therefore:
    ///
    /// 1. Revokes the credential that is being rotated.
    /// 2. Removes that credential from the job's tracked set.
    /// 3. Appends every credential returned by the provisioner to the job's
    ///    tracked set so the runtime can revoke them later — none are
    ///    silently discarded.
    /// 4. Persists the updated outstanding-id list through retention.
    ///
    /// Returns the credential identified as the replacement: the entry whose
    /// `id` matches `credentialId` if the provisioner is performing an
    /// in-place rotation, otherwise the first newly minted entry.
    public func rotate(jobId: JobId, credentialId: String) async throws -> ProvisionedCredential {
        guard let lease = leaseByJob[jobId] else {
            throw ARCPError.notFound(kind: "job credentials", id: jobId.rawValue)
        }
        let next = try await provisioner.issue(lease: lease, jobId: jobId, sessionId: sessionId)
        guard !next.isEmpty else {
            throw ARCPError.unavailable(
                reason: "credential rotation returned no credentials",
                retryAfter: nil
            )
        }
        var existing = credentialsByJob[jobId] ?? []
        if existing.contains(where: { $0.id == credentialId }) {
            await revokeWithRetry(credentialId, jobId: jobId)
            existing.removeAll { $0.id == credentialId }
        }
        existing.append(contentsOf: next)
        credentialsByJob[jobId] = existing
        try await retention.persistOutstanding(existing.map(\.id), jobId: jobId)
        let replacement = next.first(where: { $0.id == credentialId }) ?? next[0]
        return replacement
    }

    private func revokeWithRetry(_ credentialId: String, jobId: JobId) async {
        var delay: UInt64 = 100_000_000
        var lastError: (any Error)?
        for attempt in 0..<3 {
            do {
                try await provisioner.revoke(credentialId: credentialId)
                return
            } catch {
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: delay)
                    delay *= 2
                }
            }
        }
        // §9.8.2 / §14: revocation is best-effort, but a permanent failure
        // MUST be logged so operators can surface the dangling spend authority.
        log.error(
            "credential revocation failed permanently after retries",
            metadata: [
                "credential_id": "\(credentialId)",
                "job_id": "\(jobId.rawValue)",
                "session": "\(sessionId)",
                "error": "\(String(describing: lastError))",
            ]
        )
    }
}
