// ARCP v1.1 §10.3 / §17.1 — distributed trace context propagation.
//
// Every envelope carries first-class trace fields:
//
//   Envelope.traceId      — W3C-compatible 128-bit trace identifier
//   Envelope.spanId       — 64-bit span identifier for this hop
//   Envelope.parentSpanId — links to the parent span in the call tree
//   Envelope.extensions   — carries the W3C `traceparent` header (§10.3)
//
// This sample shows the full propagation lifecycle:
//
//   1. Client creates a root `TraceContext` and derives a child span.
//   2. `Tracing.withTrace` installs it as the Swift task-local current trace.
//   3. The client stamps the `tool.invoke` envelope with traceId/spanId and
//      injects a W3C `traceparent` into `extensions`.
//   4. The server-side agent reads `invocation.traceId` and logs it — any
//      downstream HTTP call can extract the W3C header and continue the span.
//   5. After the job completes the client emits a `trace.span` envelope
//      (RFC §17.1) — the runtime persists it; use this as the "exporter" hook.
//
// Note: `trace.span` envelopes sent by the client are logged & persisted by
// the runtime but are NOT echoed back to other sessions.

import ARCP
import Foundation

// ---------------------------------------------------------------------------
// Agent — reads the propagated trace ID and logs it
// ---------------------------------------------------------------------------

struct TracedAgent: ToolHandler {
    let name = "traced-work"

    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        // The agent receives the caller's traceId from the ToolInvocation.
        // In a real implementation you would propagate it to every downstream
        // HTTP/gRPC call by injecting the `traceparent` header.
        if let tid = invocation.traceId {
            try await context.log(
                level: .info,
                message: "trace propagated  trace_id=\(tid.rawValue)",
                attributes: nil
            )
        } else {
            try await context.log(level: .warn, message: "no trace_id on invocation", attributes: nil)
        }

        // Simulate two phases of work, logging a span around each.
        try await context.log(level: .info, message: "phase 1: fetch", attributes: nil)
        try await Task.sleep(for: .milliseconds(20))
        try await context.log(level: .info, message: "phase 2: transform", attributes: nil)
        try await Task.sleep(for: .milliseconds(20))

        return .value(.string("traced result"))
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build a W3C traceparent header value for the given context.
/// Format: `"00-<traceId>-<spanId>-01"` (sampled).
func makeTraceparent(context: TraceContext) -> String {
    "00-\(context.traceId.rawValue)-\(context.spanId.rawValue)-01"
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

@main
struct TracingExample {
    static func main() async throws {
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "tracing-demo", version: "1.0.0"),
            supportedCapabilities: Capabilities(),
            auth: BearerAuthValidator(subjectsByToken: ["demo-token": "demo"])
        )
        await runtime.register(TracedAgent())
        let server = Task { try await runtime.acceptSession(over: pair.server) }

        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "demo-token"),
            client: IdentityBlock(kind: "tracing-demo-client", version: "1.0.0"),
            capabilities: Capabilities()
        )

        // ── Build a trace context hierarchy. ──
        //
        //   rootCtx  — the top-level trace for this logical request
        //   invokeCtx — child span scoped to the tool.invoke call
        //
        let rootCtx = TraceContext.newTrace()
        let invokeCtx = rootCtx.childSpan()
        print("root  trace_id=\(rootCtx.traceId.rawValue)  span_id=\(rootCtx.spanId.rawValue)")
        print("child trace_id=\(invokeCtx.traceId.rawValue)  span_id=\(invokeCtx.spanId.rawValue)  parent=\(invokeCtx.parentSpanId?.rawValue ?? "(none)")")

        // Record when the client span begins so we can compute its duration.
        let spanStart = Date()

        // ── Stamp and send the tool.invoke envelope. ──
        //
        // `Tracing.withTrace` installs `invokeCtx` as the Swift task-local
        // `Tracing.current` for any code running inside the closure.
        //
        var invokedEnvId: MessageId?
        try await Tracing.withTrace(invokeCtx) {
            let traceparent = makeTraceparent(context: invokeCtx)

            let invoke = Envelope(
                sessionId: client.info.sessionId,
                // First-class ARCP trace fields (RFC §10.3).
                traceId:      invokeCtx.traceId,
                spanId:       invokeCtx.spanId,
                parentSpanId: invokeCtx.parentSpanId,
                // W3C traceparent in the extensions map — forwarded to
                // downstream HTTP calls inside the agent or any proxy.
                extensions: ["traceparent": .string(traceparent)],
                payload: .toolInvoke(
                    ToolInvokePayload(
                        tool: "traced-work",
                        arguments: .object(["data": .string("hello")])
                    )
                )
            )
            invokedEnvId = invoke.id
            try await client.send(invoke)
            print("→ tool.invoke sent  traceparent=\(traceparent)")
        }

        // ── Drain events, printing any trace annotation on each envelope. ──
        var spanEnd: Date = spanStart
        for await env in client.unhandled {
            let traceTag = env.traceId.map { "  trace=\($0.rawValue.prefix(8))" } ?? ""
            switch env.payload {
            case .jobAccepted(let p):
                print("← job.accepted   job_id=\(p.jobId.rawValue.prefix(8))\(traceTag)")

            case .log(let p):
                print("← log[\(p.level)]     \(p.message)\(traceTag)")

            case .jobCompleted(let p):
                spanEnd = Date()
                print("← job.completed  result=\(p.result?.stringValue ?? "(nil)")\(traceTag)")

                // ── Emit a client-side trace span (RFC §17.1). ──
                //
                // The client acts as an exporter: after the job resolves it
                // records a `trace.span` envelope covering the entire
                // tool.invoke → job.completed round-trip. The runtime
                // persists this span; plug an OTLP exporter here in production.
                //
                let span = Envelope(
                    sessionId: client.info.sessionId,
                    traceId:   invokeCtx.traceId,
                    spanId:    invokeCtx.spanId,
                    payload: .traceSpan(
                        TraceSpanPayload(
                            name:       "client.tool_invoke",
                            startedAt:  spanStart,
                            endedAt:    spanEnd,
                            attributes: [
                                "tool":       .string("traced-work"),
                                "session_id": .string(client.info.sessionId.rawValue),
                                "env_id":     .string(invokedEnvId?.rawValue ?? "")
                            ],
                            status: "OK"
                        )
                    )
                )
                try await client.send(span)
                let latencyMs = Int(spanEnd.timeIntervalSince(spanStart) * 1000)
                print("→ trace.span emitted  name=client.tool_invoke  latency=\(latencyMs)ms")

                await client.close()
                _ = try? await server.value
                return

            case .jobFailed(let p):
                print("← job.failed  \(p.error.message)\(traceTag)")
                await client.close()
                _ = try? await server.value
                return

            default:
                break
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

extension JSONValue {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    subscript(key: String) -> JSONValue? {
        if case .object(let d) = self { return d[key] }
        return nil
    }
}
