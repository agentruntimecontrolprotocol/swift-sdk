import Foundation

/// Server-side handler for a registered tool. RFC §10.
///
/// Implementations receive an invocation, run the work using the supplied
/// `JobContext` to report progress and stream output, and either return a
/// `ToolOutput` value (for direct invocations) or throw an `ARCPError`.
public protocol ToolHandler: Sendable {
    /// Tool name, matching `tool.invoke.payload.tool`.
    var name: String { get }

    /// Execute the tool. Cooperative cancellation: the handler should call
    /// `try Task.checkCancellation()` periodically (or `await context.checkCancellation()`).
    func execute(
        invocation: ToolInvocation,
        context: any JobContext
    ) async throws -> ToolOutput
}

/// Inputs handed to a `ToolHandler`.
public struct ToolInvocation: Sendable {
    public let jobId: JobId
    public let sessionId: SessionId
    public let arguments: JSONValue
    public let idempotencyKey: IdempotencyKey?
    public let traceId: TraceId?

    public init(
        jobId: JobId,
        sessionId: SessionId,
        arguments: JSONValue,
        idempotencyKey: IdempotencyKey? = nil,
        traceId: TraceId? = nil
    ) {
        self.jobId = jobId
        self.sessionId = sessionId
        self.arguments = arguments
        self.idempotencyKey = idempotencyKey
        self.traceId = traceId
    }
}

/// Successful tool result. `ref` is for non-inlined (artifact-backed)
/// results; `streamed` is for results delivered as a sequence of
/// `job.result_chunk` events (ARCP v1.1 §8.4), where the terminating
/// `job.completed` carries `resultId` / `resultSize` / `summary`
/// markers instead of an inline value.
public enum ToolOutput: Sendable {
    case value(JSONValue)
    case ref(ArtifactRef)
    case empty
    /// Result was streamed as `job.result_chunk` events; the terminal
    /// `job.completed` envelope references the same `resultId`.
    case streamed(resultId: String, size: UInt64?, summary: String?)
}
