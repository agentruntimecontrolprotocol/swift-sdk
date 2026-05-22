import Foundation

public struct LeaseSnapshot: Sendable, Hashable {
    public let costBudget: CostBudget?
    public let modelUse: ModelUse?
    public let expiresAt: Date?

    public init(costBudget: CostBudget? = nil, modelUse: ModelUse? = nil, expiresAt: Date? = nil) {
        self.costBudget = costBudget
        self.modelUse = modelUse
        self.expiresAt = expiresAt
    }

    public var isEmpty: Bool {
        costBudget == nil && modelUse == nil && expiresAt == nil
    }
}

public protocol CredentialProvisioner: Sendable {
    func issue(
        lease: LeaseSnapshot, jobId: JobId, sessionId: SessionId
    ) async throws
        -> [ProvisionedCredential]
    func revoke(credentialId: String) async throws
}

public actor InMemoryCredentialProvisioner: CredentialProvisioner {
    public private(set) var issued: [ProvisionedCredential] = []
    public private(set) var revoked: [String] = []

    public init() {}

    public func issue(
        lease: LeaseSnapshot, jobId: JobId, sessionId: SessionId
    ) async throws
        -> [ProvisionedCredential]
    {
        let suffix = issued.count
        let credential = try ProvisionedCredential(
            id: "cred_\(jobId.rawValue)_\(suffix)",
            scheme: .bearer,
            value: "test-token-\(jobId.rawValue)-\(suffix)",
            endpoint: "https://credentials.example.test",
            profile: "test",
            constraints: CredentialConstraints(
                costBudget: lease.costBudget,
                modelUse: lease.modelUse,
                expiresAt: lease.expiresAt
            )
        )
        issued.append(credential)
        return [credential]
    }

    public func revoke(credentialId: String) async throws {
        revoked.append(credentialId)
    }
}
