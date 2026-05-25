import Foundation
import Testing

@testable import ARCP

@Suite("Trace context propagation")
struct TraceContextTests {
    @Test("child spans preserve trace id and point at parent span")
    func childSpan() {
        let root = TraceContext(
            traceId: TraceId("trace_root"),
            spanId: SpanId("span_root")
        )
        let child = root.childSpan()
        #expect(child.traceId == root.traceId)
        #expect(child.spanId != root.spanId)
        #expect(child.parentSpanId == root.spanId)
    }

    @Test("Envelope inherits ambient async trace when fields are omitted")
    func asyncEnvelopeInheritance() async throws {
        let context = TraceContext(
            traceId: TraceId("trace_async"),
            spanId: SpanId("span_async"),
            parentSpanId: SpanId("span_parent")
        )
        let envelope = try await Tracing.withTrace(context) {
            try await Task.sleep(for: .milliseconds(1))
            return Envelope(payload: .ping(PingPayload(nonce: "n")))
        }
        #expect(envelope.traceId == context.traceId)
        #expect(envelope.spanId == context.spanId)
        #expect(envelope.parentSpanId == context.parentSpanId)
    }

    @Test("Explicit envelope trace fields override ambient trace")
    func explicitTraceWins() {
        let context = TraceContext(
            traceId: TraceId("trace_outer"),
            spanId: SpanId("span_outer")
        )
        let envelope = Tracing.withTrace(context) {
            Envelope(
                traceId: TraceId("trace_explicit"),
                spanId: SpanId("span_explicit"),
                parentSpanId: SpanId("span_explicit_parent"),
                payload: .ping(PingPayload())
            )
        }
        #expect(envelope.traceId == TraceId("trace_explicit"))
        #expect(envelope.spanId == SpanId("span_explicit"))
        #expect(envelope.parentSpanId == SpanId("span_explicit_parent"))
    }

    @Test("newTrace creates a root trace")
    func newTrace() {
        let context = TraceContext.newTrace()
        #expect(context.traceId.rawValue.hasPrefix("trace_"))
        #expect(context.spanId.rawValue.hasPrefix("span_"))
        #expect(context.parentSpanId == nil)
    }
}
