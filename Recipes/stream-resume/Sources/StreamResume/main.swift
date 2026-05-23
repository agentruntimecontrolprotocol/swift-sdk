/// Recipe: Stream Resume
///
/// Demonstrates crash-and-resume for a streamed result. A writer agent emits
/// 10 result chunks. The client reads 4 chunks then "crashes" (breaks the
/// iterator). It re-submits the same idempotency key — the runtime returns the
/// same job_id — and resumes consuming the buffered remainder from the same
/// ResultChunkStream.
///
/// Spec: §10 (resumability), §19 (durable jobs), §7.2 (idempotency)
///
/// Run:
///   cd Recipes/stream-resume && swift run

import ARCP
import Foundation

// MARK: - Writer agent

/// Emits `totalChunks` result chunks and returns a `.streamed` output.
struct WriterAgent: ToolHandler {
    let name = "report.write"

    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        let resultId    = "doc-\(invocation.jobId.rawValue.prefix(8))"
        let totalChunks: UInt64 = 10
        var totalBytes: UInt64  = 0

        try await context.log(
            level: .info,
            message: "writing report: \(totalChunks) chunks",
            attributes: nil
        )

        for i in 0..<totalChunks {
            let more     = (i + 1) < totalChunks
            let fragment = "# Section \(i + 1)\nLorem ipsum paragraph \(i + 1).\n"
            totalBytes  += UInt64(fragment.utf8.count)

            try await context.emitResultChunk(
                resultId: resultId,
                chunkSeq: i,
                data:     fragment,
                encoding: .utf8,
                more:     more
            )
            try await Task.sleep(for: .milliseconds(15))
        }

        try await context.log(
            level: .info,
            message: "report written: \(totalBytes) bytes",
            attributes: nil
        )

        return .streamed(
            resultId: resultId,
            size:     totalBytes,
            summary:  "report with \(totalChunks) sections"
        )
    }
}

// MARK: - Main

@main struct StreamResume {
    static func main() async throws {
        let pair = MemoryTransport.makePair()

        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "stream-resume-runtime", version: "1.0.0"),
            supportedCapabilities: Capabilities(durableJobs: true),
            auth: BearerAuthValidator(subjectsByToken: ["demo-token": "client"])
        )
        await runtime.register(WriterAgent())
        let server = Task { try await runtime.acceptSession(over: pair.server) }

        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "demo-token"),
            client: IdentityBlock(kind: "stream-resume-client", version: "1.0.0"),
            capabilities: Capabilities(durableJobs: true)
        )

        // ── Phase 1: submit and collect first 4 chunks ───────────────────────

        let idempotencyKey = IdempotencyKey(rawValue: "report-write-001")

        let env = Envelope(
            sessionId:      client.info.sessionId,
            idempotencyKey: idempotencyKey,
            payload: .toolInvoke(ToolInvokePayload(
                tool:      "report.write",
                arguments: .object([:])
            ))
        )
        try await client.send(env)
        print("→ report.write submitted  key=\(idempotencyKey.rawValue)")

        // Wait for job.accepted to get the job_id
        var jobId: JobId?
        for await reply in client.unhandled {
            if case .jobAccepted(let p) = reply.payload {
                jobId = p.jobId
                print("← job.accepted  job_id=\(p.jobId.rawValue.prefix(8))")
                break
            }
        }
        guard let jobId else { throw ARCPError.aborted(reason: "no job.accepted") }

        // Open the ResultChunkStream before consuming chunks
        let chunkStream = await client.resultChunks(for: jobId)

        print("→ phase 1: collecting first 4 chunks (simulating crash after chunk 4)...")
        var lastSeq: UInt64 = 0
        var phase1Count     = 0
        for try await chunk in chunkStream {
            lastSeq = chunk.chunkSeq
            phase1Count += 1
            print("   chunk  seq=\(chunk.chunkSeq)  size=\(chunk.data.utf8.count)b")
            if phase1Count >= 4 { break }  // ← simulated crash / connection drop
        }
        print("← phase 1: received \(phase1Count) chunks (last seq=\(lastSeq))")

        // ── Phase 2: re-submit same key, resume from buffered remainder ──────

        print("→ phase 2: re-submitting same idempotency key...")
        try await client.send(Envelope(
            sessionId:      client.info.sessionId,
            idempotencyKey: idempotencyKey,
            payload: .toolInvoke(ToolInvokePayload(
                tool:      "report.write",
                arguments: .object([:])
            ))
        ))

        // Runtime deduplicates: same key → same job_id (RFC §7.2)
        for await reply in client.unhandled {
            if case .jobAccepted(let p) = reply.payload {
                if p.jobId == jobId {
                    print("← job.accepted  job_id=\(p.jobId.rawValue.prefix(8))  (same — idempotent ✓)")
                } else {
                    print("← job.accepted  job_id=\(p.jobId.rawValue.prefix(8))  (UNEXPECTED: new job_id)")
                }
                break
            }
        }

        // Resume consuming the same stream — buffered chunks 4–9 are still available
        print("→ consuming remaining chunks from buffered stream...")
        var phase2Count = 0
        for try await chunk in chunkStream {
            phase2Count += 1
            print("   chunk  seq=\(chunk.chunkSeq)  size=\(chunk.data.utf8.count)b")
        }
        print("← phase 2: received \(phase2Count) more chunks")

        let total = phase1Count + phase2Count
        print("← total: \(total) chunks (expected 10)  \(total == 10 ? "✓" : "✗")")

        // Drain remaining control events
        for await reply in client.unhandled {
            switch reply.payload {
            case .log(let p):
                print("← log[\(p.level)]  \(p.message)")
            case .jobCompleted(let p):
                print("← job.completed  summary=\(p.summary ?? "?")")
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
