import Foundation

/// Context passed to a `ToolHandler` — provides progress reporting,
/// streaming, cancellation observation, and (Phase 4+) permission/HITL hooks.
public protocol JobContext: Sendable {
    var jobId: JobId { get }
    var sessionId: SessionId { get }

    /// Emit `job.progress`. Percent must be 0...100 if provided. RFC §10.1.
    func reportProgress(
        percent: Double?, message: String?, attributes: [String: JSONValue]?)
        async
        throws

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
}

/// Handle returned by `JobContext.openStream` for emitting chunks until close.
public protocol StreamHandle: Sendable {
    var streamId: StreamId { get }
    func sendText(_ text: String, sequence: Int?) async throws
    func sendChunk(_ payload: StreamChunkPayload) async throws
    func close(reason: String?) async throws
    func error(_ error: ARCPError) async throws
}
