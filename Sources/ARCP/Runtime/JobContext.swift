import Foundation

/// Context passed to a `ToolHandler` — provides progress reporting,
/// streaming, cancellation observation, and (Phase 4+) permission/HITL hooks.
public protocol JobContext: Sendable {
    var jobId: JobId { get }
    var sessionId: SessionId { get }

    /// The `lease_constraints.expires_at` declared on `tool.invoke`,
    /// if any (ARCP v1.1 §9.5). `nil` means the lease has no expiry.
    var leaseExpiresAt: Date? { get }

    /// Throw ``ARCPError/leaseExpired(leaseId:expiredAt:)`` when the
    /// lease's `expires_at` has elapsed (ARCP v1.1 §9.5). No-op when
    /// the lease has no expiry. Handlers SHOULD invoke this before
    /// each authority-bearing operation.
    func checkLeaseExpiration() throws

    /// Per-job `cost.budget` tracker (ARCP v1.1 §9.6). Always present;
    /// the tracker is empty when no `cost_budget` was supplied on
    /// `tool.invoke`. Use ``charge(name:amount:currency:)`` to report
    /// cost and have the runtime decrement counters.
    var budget: BudgetTracker { get }

    /// Charge `amount` against the `currency` counter and emit a
    /// matching `metric` event (ARCP v1.1 §9.6).
    ///
    /// `name` SHOULD begin with `cost.`. After the charge a
    /// `cost.budget.remaining` metric is emitted with the new counter
    /// so clients can render gauges. Returns
    /// ``ARCPError/budgetExhausted(detail:)`` when the counter is at
    /// or below zero before the charge.
    func charge(name: String, amount: Double, currency: String) async throws

    /// Check a model identifier against the job's `model.use` lease.
    func checkModelUse(_ model: String) throws

    /// Rotate a lease-bound provisioned credential for this job.
    func rotateCredential(id: String) async throws -> ProvisionedCredential

    /// Emit `job.progress`. Percent must be 0...100 if provided. RFC §10.1.
    func reportProgress(
        percent: Double?, message: String?, attributes: [String: JSONValue]?)
        async
        throws

    /// Emit `job.progress` with the v1.1 §8.2.1 structured body
    /// (`current` / `total` / `units` / `message`). `total` may be omitted
    /// when the work is indeterminate.
    func reportProgress(
        current: Double,
        total: Double?,
        units: String?,
        message: String?
    ) async throws

    /// Open a fresh stream and return a `StreamHandle` for sending chunks.
    /// RFC §11.
    func openStream(
        kind: StreamKind, contentType: String?, encoding: String?
    ) async throws
        -> any StreamHandle

    /// Throw `ARCPError.cancelled` if the job has been requested to cancel.
    func checkCancellation() async throws

    /// Emit a `log` envelope. RFC §17.2.
    func log(level: LogLevel, message: String, attributes: [String: JSONValue]?) async throws

    /// Emit a `metric` envelope. RFC §17.3.
    func metric(name: String, value: Double, unit: String?, dims: [String: JSONValue]?) async throws

    /// Request structured input from a human. RFC §12.1. Blocks the calling
    /// task until a response arrives or `expiresAt` elapses (in which case
    /// the configured default is synthesized, or the request is cancelled).
    func requestHumanInput(
        prompt: String,
        responseSchema: JSONValue?,
        default: JSONValue?,
        expiresIn: Duration
    ) async throws -> HumanInputResponsePayload

    /// Request a multi-option human choice. RFC §12.2.
    func requestHumanChoice(
        prompt: String,
        options: [HumanChoiceRequestPayload.Option],
        expiresIn: Duration
    ) async throws -> HumanChoiceResponsePayload

    /// Request a permission grant. RFC §15.4. Blocks until the client
    /// returns `permission.grant` or `permission.deny`.
    func requestPermission(
        permission: String,
        resource: String,
        operation: String,
        reason: String?,
        leaseSeconds: Int
    ) async throws -> LeaseId

    /// Emit a single `job.result_chunk` fragment (ARCP v1.1 §8.4).
    ///
    /// `chunkSeq` is the caller's responsibility — start at 0 and
    /// increment per chunk for the same `resultId`. The terminal chunk
    /// MUST set `more: false`; the job's terminal `job.completed` SHOULD
    /// then carry the same `resultId` (use `ToolOutput.streamed`).
    func emitResultChunk(
        resultId: String,
        chunkSeq: UInt64,
        data: String,
        encoding: ResultChunkEncoding,
        more: Bool
    ) async throws
}

extension JobContext {
    /// Emit `job.progress` with the v1.1 §8.2.1 structured body.
    ///
    /// - Parameters:
    ///   - current: Non-negative count of completed units of work.
    ///   - total: Optional total; absent means indeterminate.
    ///   - units: Optional unit label, e.g. `"files"`, `"tokens"`.
    ///   - message: Optional human-readable status line.
    public func reportProgress(
        current: Double,
        total: Double? = nil,
        units: String? = nil,
        message: String? = nil
    ) async throws {
        // Default routing: pack v1.1 fields into the legacy attributes bag so
        // implementations that have not adopted the structured fields still
        // observe the data. Concrete contexts (e.g. ConcreteJobContext) MAY
        // override to emit `current`/`total`/`units` as first-class fields
        // on the wire per §8.2.1.
        var attrs: [String: JSONValue] = [:]
        attrs["current"] = .double(current)
        if let total { attrs["total"] = .double(total) }
        if let units { attrs["units"] = .string(units) }
        var derivedPercent: Double?
        if let total, total > 0 {
            derivedPercent = (current / total) * 100.0
        }
        try await reportProgress(
            percent: derivedPercent,
            message: message,
            attributes: attrs
        )
    }
}

/// Handle returned by `JobContext.openStream` for emitting chunks until close.
public protocol StreamHandle: Sendable {
    var streamId: StreamId { get }
    func sendText(_ text: String, sequence: Int?) async throws
    func sendChunk(_ payload: StreamChunkPayload) async throws
    func close(reason: String?) async throws
    func error(_ error: ARCPError) async throws
}
