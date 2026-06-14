import Foundation

/// Per-session registry of **permission-challenge leases** (ARCP v1.1 §15.4).
///
/// IMPORTANT — these are the short-lived leases minted in response to a
/// `permission.grant`, NOT the job lease whose `lease_constraints.expires_at`
/// gates `JobContext.checkLeaseExpiration` (§9.5). §9.5 forbids *renewal* of a
/// job lease (a client MUST cancel and resubmit to extend authority); that
/// rule does not apply to §15.4 permission-challenge leases, which MAY be
/// refreshed via `lease.refresh` → `lease.extended`. No path here mutates a
/// job's §9.5 `expires_at`.
///
/// Leases can be refreshed, revoked (`lease.revoked`), or allowed to expire
/// naturally. A periodic sweep emits `lease.revoked` for any lease whose
/// monotonic deadline (§14) has passed.
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
            deadline: MonotonicDeadline(wallDeadline: expiresAt),
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

    /// Refresh a §15.4 permission-challenge lease, extending it by `seconds`.
    ///
    /// This applies only to permission-challenge leases held in this registry.
    /// It does NOT and MUST NOT extend a job's §9.5 `lease_constraints.expires_at`
    /// (which is renewal-prohibited — cancel and resubmit instead).
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
        if record.revoked || record.deadline.isExpired() {
            throw ARCPError.leaseExpired(leaseId: leaseId, expiredAt: record.expiresAt)
        }
        let newExpires = max(record.expiresAt, Date()).addingTimeInterval(TimeInterval(seconds))
        record.expiresAt = newExpires
        record.deadline = MonotonicDeadline(wallDeadline: newExpires)
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
        if record.deadline.isExpired() { return .expired }
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
        /// Monotonic-clock view of `expiresAt` used for expiry checks (§14).
        var deadline: MonotonicDeadline
        var costBudget: CostBudget?
        var modelUse: ModelUse?
        var revoked: Bool
    }

    private func expireDue() async {
        // §14: expiry is evaluated against the monotonic deadline, not Date().
        for (id, record) in leases where !record.revoked && record.deadline.isExpired() {
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
