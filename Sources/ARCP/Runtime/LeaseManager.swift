import Foundation

/// Per-session lease registry. RFC §15.5.
///
/// Leases are minted on `permission.grant`, can be refreshed
/// (`lease.refresh` → `lease.extended`), revoked (`lease.revoked`), or
/// allowed to expire naturally. A periodic sweep emits `lease.revoked` with
/// `LEASE_EXPIRED` for any lease whose `expiresAt` has passed.
public actor LeaseManager {
    public let sessionId: SessionId

    private let send: @Sendable (Envelope) async throws -> Void
    private var leases: [LeaseId: LeaseRecord] = [:]
    private var sweepTask: Task<Void, Never>?

    public init(
        sessionId: SessionId,
        send: @escaping @Sendable (Envelope) async throws -> Void
    ) {
        self.sessionId = sessionId
        self.send = send
    }

    public func startSweep(interval: TimeInterval = 5) {
        sweepTask?.cancel()
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch { return }
                await self?.expireDue()
            }
        }
    }

    public func stop() {
        sweepTask?.cancel()
    }

    /// Mint a new lease and emit `lease.granted`. Returns the lease id.
    @discardableResult
    public func grant(
        permission: String,
        resource: String,
        operation: String,
        seconds: Int,
        costBudget: CostBudget? = nil,
        modelUse: ModelUse? = nil
    ) async throws -> LeaseId {
        guard seconds > 0 else {
            throw ARCPError.invalidArgument(
                field: "lease_seconds",
                detail: "lease duration must be positive, got \(seconds)"
            )
        }
        let leaseId = LeaseId.random()
        let expiresAt = Date(timeIntervalSinceNow: TimeInterval(seconds))
        leases[leaseId] = LeaseRecord(
            leaseId: leaseId,
            permission: permission,
            resource: resource,
            operation: operation,
            expiresAt: expiresAt,
            costBudget: costBudget,
            modelUse: modelUse,
            revoked: false
        )
        try await send(
            Envelope(
                sessionId: sessionId,
                payload: .leaseGranted(
                    LeaseGrantedPayload(
                        leaseId: leaseId,
                        permission: permission,
                        resource: resource,
                        operation: operation,
                        expiresAt: expiresAt,
                        costBudget: costBudget,
                        modelUse: modelUse
                    )
                )
            )
        )
        return leaseId
    }

    /// Refresh a lease, extending it by `seconds`. RFC §15.5.
    public func refresh(leaseId: LeaseId, seconds: Int) async throws {
        guard seconds > 0 else {
            throw ARCPError.invalidArgument(
                field: "requested_seconds",
                detail: "lease refresh duration must be positive, got \(seconds)"
            )
        }
        guard var record = leases[leaseId] else {
            throw ARCPError.notFound(kind: "lease", id: leaseId.rawValue)
        }
        if record.revoked || record.expiresAt < Date() {
            throw ARCPError.leaseExpired(leaseId: leaseId, expiredAt: record.expiresAt)
        }
        let newExpires = max(record.expiresAt, Date()).addingTimeInterval(TimeInterval(seconds))
        record.expiresAt = newExpires
        leases[leaseId] = record
        try await send(
            Envelope(
                sessionId: sessionId,
                payload: .leaseExtended(
                    LeaseExtendedPayload(leaseId: leaseId, expiresAt: newExpires)
                )
            )
        )
    }

    /// Revoke a lease and emit `lease.revoked`.
    public func revoke(leaseId: LeaseId, reason: String) async throws {
        guard var record = leases[leaseId] else { return }
        if record.revoked { return }
        record.revoked = true
        leases[leaseId] = record
        try await send(
            Envelope(
                sessionId: sessionId,
                payload: .leaseRevoked(LeaseRevokedPayload(leaseId: leaseId, reason: reason))
            )
        )
    }

    /// Look up a lease's current status.
    public func status(_ leaseId: LeaseId) -> LeaseStatus? {
        guard let record = leases[leaseId] else { return nil }
        if record.revoked { return .revoked }
        if record.expiresAt < Date() { return .expired }
        return .active
    }

    public enum LeaseStatus: Sendable, Equatable { case active, expired, revoked }

    public func snapshot(_ leaseId: LeaseId) -> LeaseSnapshot? {
        guard let record = leases[leaseId], !record.revoked else { return nil }
        return LeaseSnapshot(
            costBudget: record.costBudget,
            modelUse: record.modelUse,
            expiresAt: record.expiresAt
        )
    }

    private struct LeaseRecord: Sendable {
        let leaseId: LeaseId
        let permission: String
        let resource: String
        let operation: String
        var expiresAt: Date
        var costBudget: CostBudget?
        var modelUse: ModelUse?
        var revoked: Bool
    }

    private func expireDue() async {
        let now = Date()
        for (id, record) in leases where !record.revoked && record.expiresAt < now {
            leases[id] = nil
            try? await send(
                Envelope(
                    sessionId: sessionId,
                    payload: .leaseRevoked(
                        LeaseRevokedPayload(leaseId: id, reason: "expired")
                    )
                )
            )
        }
    }
}
