/// Distributed-trace context propagated across `await` boundaries via `@TaskLocal`.
/// RFC §17.1.
///
/// Cross-runtime delegation **MUST** propagate `traceId`. The SDK preserves
/// `traceId` and `spanId` automatically when an envelope is built inside a
/// `Tracing.withTrace { ... }` scope.
public struct TraceContext: Sendable, Hashable, Codable {
    public let traceId: TraceId
    public let spanId: SpanId
    public let parentSpanId: SpanId?

    public init(traceId: TraceId, spanId: SpanId, parentSpanId: SpanId? = nil) {
        self.traceId = traceId
        self.spanId = spanId
        self.parentSpanId = parentSpanId
    }

    /// Mint a fresh trace with a freshly minted root span.
    public static func newTrace() -> TraceContext {
        TraceContext(traceId: .random(), spanId: .random(), parentSpanId: nil)
    }

    /// Derive a child context with a fresh `spanId`, preserving the trace.
    public func childSpan() -> TraceContext {
        TraceContext(traceId: traceId, spanId: .random(), parentSpanId: spanId)
    }
}

/// Task-local trace propagation API. Use `Tracing.withTrace` to scope a unit
/// of work to a trace context; everything launched inside (including child
/// `Task`s, `TaskGroup` children, and `await`-suspended continuations)
/// inherits the context automatically.
public enum Tracing {
    /// The current trace context, if any. Read it during envelope construction.
    @TaskLocal public static var current: TraceContext?

    /// Run `body` within `context`. Nested `withTrace` calls override.
    public static func withTrace<T>(
        _ context: TraceContext,
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await Self.$current.withValue(context) {
            try await body()
        }
    }

    /// Run sync `body` within `context`.
    public static func withTrace<T>(
        _ context: TraceContext,
        _ body: () throws -> T
    ) rethrows -> T {
        try Self.$current.withValue(context, operation: body)
    }
}
