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
}

/// Handle returned by `JobContext.openStream` for emitting chunks until close.
public protocol StreamHandle: Sendable {
    var streamId: StreamId { get }
    func sendText(_ text: String, sequence: Int?) async throws
    func sendChunk(_ payload: StreamChunkPayload) async throws
    func close(reason: String?) async throws
    func error(_ error: ARCPError) async throws
}
