// ARCP v1.1 §6.5 / §11.2 — acknowledgement-based flow control.
//
// A high-frequency streaming agent emits one stream chunk per 10 ms.
// The client deliberately acks slowly (every 500 ms). Once the runtime
// detects that its outbound buffer is growing it sends a `backpressure`
// envelope advising the sender to slow down (RFC §11.2).
//
// What this sample shows:
//   - Opening a `StreamHandle` from inside a `ToolHandler`
//   - Sending many `stream.chunk` envelopes rapidly
//   - The runtime autonomously emitting `backpressure` when the client
//     falls behind
//   - The client detecting and logging the backpressure signal
//
// Note: `BackpressurePayload` is surfaced as `.backpressure(...)` on
// the client's event stream — no additional client opt-in is needed.

import ARCP
import Foundation

// ---------------------------------------------------------------------------
// Agent — opens a text stream and floods it with chunks
// ---------------------------------------------------------------------------

struct HighFrequencyAgent: ToolHandler {
    let name = "high-frequency-data"

    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        let chunkCount = 40  // 40 chunks at 10 ms gaps = ~400 ms total

        // Open a raw text stream. The runtime assigns a `stream_id` and
        // sends `stream.open` to the client before our first chunk lands.
        let stream = try await context.openStream(
            kind: .text, contentType: "text/plain", encoding: nil
        )

        for i in 0..<chunkCount {
            try await context.checkCancellation()
            try await stream.sendText("chunk-\(i)\n", sequence: i)
            try await Task.sleep(for: .milliseconds(10))
        }

        try await stream.close(reason: nil)
        return .value(.string("streamed \(chunkCount) chunks"))
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

@main
struct AckBackpressureExample {
    static func main() async throws {
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "ack-backpressure-demo", version: "1.0.0"),
            supportedCapabilities: Capabilities(streaming: true),
            auth: BearerAuthValidator(subjectsByToken: ["demo-token": "demo"])
        )
        await runtime.register(HighFrequencyAgent())
        let server = Task { try await runtime.acceptSession(over: pair.server) }

        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "demo-token"),
            client: IdentityBlock(kind: "ack-backpressure-client", version: "1.0.0"),
            capabilities: Capabilities(streaming: true)
        )

        // Submit the job.
        let invoke = Envelope(
            sessionId: client.info.sessionId,
            payload: .toolInvoke(
                ToolInvokePayload(tool: "high-frequency-data", arguments: .null)
            )
        )
        try await client.send(invoke)
        print("→ tool.invoke sent")

        var chunksSeen = 0
        var backpressureSeen = false

        for await env in client.unhandled {
            switch env.payload {
            case .jobAccepted(let p):
                print("← job.accepted  job_id=\(p.jobId.rawValue.prefix(8))")

            case .streamOpen(let p):
                print("← stream.open   stream_id=\(p.streamId.rawValue.prefix(8))")

            case .streamChunk:
                chunksSeen += 1
                // Simulate a slow consumer: ack only every 10th chunk,
                // with an artificial delay — this lets the buffer grow.
                if chunksSeen % 10 == 0 {
                    try await Task.sleep(for: .milliseconds(200))
                    try await client.send(
                        Envelope(
                            sessionId: client.info.sessionId,
                            payload: .ack(AckPayload(detail: "acked \(chunksSeen) chunks"))
                        )
                    )
                }

            case .backpressure(let p):
                backpressureSeen = true
                let rate = p.desiredRatePerSecond.map { "\($0) msg/s" } ?? "unspecified rate"
                let buf  = p.bufferRemainingBytes.map { "\($0) bytes remaining" } ?? ""
                print("← backpressure  desired=\(rate)  \(buf)  reason=\(p.reason ?? "none")")
                // RFC §11.2 — honour the signal: slow down.
                try await Task.sleep(for: .milliseconds(500))

            case .streamClose:
                print("← stream.close  (chunks received: \(chunksSeen))")

            case .jobCompleted:
                print("← job.completed  backpressure_observed=\(backpressureSeen)")
                await client.close()
                _ = try? await server.value
                return

            default:
                break
            }
        }
    }
}
