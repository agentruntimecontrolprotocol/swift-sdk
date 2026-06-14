import Foundation

extension Duration {
    /// Approximate seconds count, including fractional part.
    public var timeInterval: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1.0e18
    }
}

/// Concrete `JobContext` implementation backed by the runtime's send hook.
struct ConcreteJobContext: JobContext, Sendable {
    let jobId: JobId
    let sessionId: SessionId
    let sendEnvelope: @Sendable (Envelope) async throws -> Void
    let streamManager: StreamManager
    let manager: JobManager
    let isCancelledProvider: @Sendable () async -> Bool
    let leaseExpiresAt: Date?
    let budget: BudgetTracker
    let modelUse: ModelUse?
    let credentialManager: CredentialManager?
    let invokeCorrelationId: MessageId

    func checkLeaseExpiration() throws {
        guard let leaseExpiresAt, Date() >= leaseExpiresAt else { return }
        throw ARCPError.leaseExpired(
            leaseId: LeaseId("lease_job_\(jobId.rawValue)"),
            expiredAt: leaseExpiresAt
        )
    }

    func charge(name: String, amount: Double, currency: String) async throws {
        let remaining = try budget.charge(currency: currency, amount: amount)
        let dims: [String: JSONValue] = ["currency": .string(currency)]
        try await metric(name: name, value: amount, unit: currency, dims: dims)
        try await metric(
            name: "cost.budget.remaining",
            value: remaining.isFinite ? remaining : Double.greatestFiniteMagnitude,
            unit: currency,
            dims: dims
        )
    }

    func checkModelUse(_ model: String) throws {
        try ModelUsePolicy.check(modelUse, model: model)
    }

    func rotateCredential(id: String) async throws -> ProvisionedCredential {
        guard let credentialManager else {
            throw ARCPError.failedPrecondition(detail: "credential provisioner is not configured")
        }
        let credential = try await credentialManager.rotate(jobId: jobId, credentialId: id)
        try await log(
            level: .info,
            message: "credential rotated",
            attributes: [
                "phase": .string("credential_rotated"),
                "credential_id": .string(id),
            ]
        )
        return credential
    }

    func reportProgress(
        percent: Double?,
        message: String?,
        attributes: [String: JSONValue]?
    ) async throws {
        try await sendEnvelope(
            Envelope(
                sessionId: sessionId,
                jobId: jobId,
                payload: .jobProgress(
                    JobProgressPayload(percent: percent, message: message, attributes: attributes)
                )
            )
        )
    }

    /// Concrete override emitting the §8.2.1 fields directly on the wire.
    func reportProgress(
        current: Double,
        total: Double? = nil,
        units: String? = nil,
        message: String? = nil
    ) async throws {
        // §8.2.1: `current` MUST be a non-negative number and SHOULD be
        // <= total when total is present. Reject non-conformant values
        // before they reach the wire.
        guard current >= 0, current.isFinite else {
            throw ARCPError.invalidArgument(
                field: "current",
                detail: "progress current must be a non-negative finite number, got \(current)"
            )
        }
        if let total, current > total {
            throw ARCPError.invalidArgument(
                field: "current",
                detail: "progress current \(current) exceeds total \(total)"
            )
        }
        try await sendEnvelope(
            Envelope(
                sessionId: sessionId,
                jobId: jobId,
                payload: .jobProgress(
                    JobProgressPayload(
                        current: current,
                        total: total,
                        units: units,
                        message: message
                    )
                )
            )
        )
    }

    func openStream(
        kind: StreamKind,
        contentType: String?,
        encoding: String?
    ) async throws -> any StreamHandle {
        try await streamManager.openOutbound(
            jobId: jobId,
            kind: kind,
            contentType: contentType,
            encoding: encoding
        )
    }

    func checkCancellation() async throws {
        try Task.checkCancellation()
        if await isCancelledProvider() {
            throw ARCPError.cancelled(operation: "job \(jobId)", reason: "cancel requested")
        }
    }

    func log(level: LogLevel, message: String, attributes: [String: JSONValue]?) async throws {
        try await sendEnvelope(
            Envelope(
                sessionId: sessionId,
                jobId: jobId,
                payload: .log(LogPayload(level: level, message: message, attributes: attributes))
            )
        )
    }

    func metric(
        name: String,
        value: Double,
        unit: String?,
        dims: [String: JSONValue]?
    ) async throws {
        try await sendEnvelope(
            Envelope(
                sessionId: sessionId,
                jobId: jobId,
                payload: .metric(MetricPayload(name: name, value: value, unit: unit, dims: dims))
            )
        )
    }

    func requestPermission(
        permission: String,
        resource: String,
        operation: String,
        reason: String?,
        leaseSeconds: Int
    ) async throws -> LeaseId {
        try await manager.requestPermission(
            jobId: jobId,
            permission: permission,
            resource: resource,
            operation: operation,
            reason: reason,
            leaseSeconds: leaseSeconds,
            timeout: .seconds(300)
        )
    }

    func emitResultChunk(
        resultId: String,
        chunkSeq: UInt64,
        data: String,
        encoding: ResultChunkEncoding,
        more: Bool
    ) async throws {
        await manager.recordResultChunk(jobId: jobId, resultId: resultId)
        try await sendEnvelope(
            Envelope(
                sessionId: sessionId,
                jobId: jobId,
                payload: .jobResultChunk(
                    JobResultChunkPayload(
                        resultId: resultId,
                        chunkSeq: chunkSeq,
                        data: data,
                        encoding: encoding,
                        more: more
                    )
                )
            )
        )
    }
}
