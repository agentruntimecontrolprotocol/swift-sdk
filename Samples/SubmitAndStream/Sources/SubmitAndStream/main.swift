// ARCP v1.1 §13.1 — canonical job lifecycle.
//
// Submits one tool invocation and streams every event kind back to the
// client before the terminal `job.completed`. The agent emits:
//
//   job.progress  — two phase updates (0 % → 50 %)
//   log           — free-text diagnostic line (RFC §17.2)
//   metric        — rolling cost.usd tally      (RFC §17.3)
//   job.completed — terminal; carries inline result
//
// This is the "hello world" of ARCP: one job_id, one stream, inspect the
// envelope sequence end-to-end.

import ARCP
import Foundation

// ---------------------------------------------------------------------------
// Agent
// ---------------------------------------------------------------------------

struct SummarizerAgent: ToolHandler {
    let name = "summarizer"

    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        let text = invocation.arguments["text"]?.stringValue ?? "(no text)"

        // Phase 1 — announce start.
        try await context.reportProgress(percent: 0, message: "starting summarization", attributes: nil)
        try await context.log(level: .info, message: "received \(text.count) chars", attributes: nil)
        try await Task.sleep(for: .milliseconds(50))

        // Phase 2 — half-way.
        try await context.reportProgress(percent: 50, message: "halfway through", attributes: nil)

        // Charge a small cost.
        try await context.metric(
            name: StandardMetric.costUsd,
            value: 0.0004,
            unit: StandardMetric.unit(for: StandardMetric.costUsd),
            dims: ["model": "demo-llm"]
        )
        try await Task.sleep(for: .milliseconds(50))

        // Done.
        try await context.reportProgress(percent: 100, message: "done", attributes: nil)
        try await context.log(level: .info, message: "summary complete", attributes: nil)

        let summary = "Summary: \(String(text.prefix(40)))…"
        return .value(.string(summary))
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

@main
struct SubmitAndStreamExample {
    static func main() async throws {
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "submit-and-stream-demo", version: "1.0.0"),
            supportedCapabilities: Capabilities(),
            auth: BearerAuthValidator(subjectsByToken: ["demo-token": "demo"])
        )
        await runtime.register(SummarizerAgent())
        let server = Task { try await runtime.acceptSession(over: pair.server) }

        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "demo-token"),
            client: IdentityBlock(kind: "submit-and-stream-client", version: "1.0.0"),
            capabilities: Capabilities()
        )

        // Submit the job.
        let invoke = Envelope(
            sessionId: client.info.sessionId,
            payload: .toolInvoke(
                ToolInvokePayload(
                    tool: "summarizer",
                    arguments: .object([
                        "text": .string(
                            "The Agent Runtime Control Protocol (ARCP) defines a wire protocol "
                            + "for controlling AI agent jobs: submitting work, streaming events, "
                            + "cancelling, and resuming across restarts."
                        )
                    ])
                )
            )
        )
        try await client.send(invoke)
        print("→ tool.invoke sent (correlation=\(invoke.id.rawValue.prefix(8)))")

        // Stream events until terminal.
        for await env in client.unhandled {
            switch env.payload {
            case .jobAccepted(let p):
                print("← job.accepted  job_id=\(p.jobId.rawValue.prefix(8))")

            case .jobProgress(let p):
                let pct = p.percent.map { String(format: "%.0f%%", $0) } ?? "?"
                print("← job.progress  \(pct)  \(p.message ?? "")")

            case .log(let p):
                print("← log[\(p.level)]   \(p.message)")

            case .metric(let p):
                print("← metric  \(p.name)=\(p.value)\(p.unit.map { " \($0)" } ?? "")")

            case .jobCompleted(let p):
                let result = p.result?.stringValue ?? p.summary ?? "(no result)"
                print("← job.completed  result=\(result)")
                // Terminal — stop consuming the stream.
                await client.close()
                _ = try? await server.value
                return

            case .jobFailed(let p):
                print("← job.failed  \(p.error.message)")
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
