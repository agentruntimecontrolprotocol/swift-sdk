// ARCP v1.1 §8.4 — `job.result_chunk` streamed-result demo.
//
// Hosts a `report-builder` agent that emits its final result as a
// sequence of `job.result_chunk` events, then completes with a
// `job.completed` referencing the streamed `result_id`. The client
// uses `ResultChunkAssembler` to reassemble the chunks.

import ARCP
import Foundation

struct ReportBuilder: ToolHandler {
    let name = "report-builder"

    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        let total: UInt64 = {
            if case .object(let obj) = invocation.arguments,
                case .int(let n) = obj["chunks"] ?? .null
            {
                return UInt64(n)
            }
            return 8
        }()
        let resultId = "res_\(invocation.jobId.rawValue)"
        var bytes: UInt64 = 0
        for i in 0..<total {
            let more = (i + 1) < total
            let fragment = "Section \(i + 1): lorem ipsum dolor sit amet\n"
            bytes += UInt64(fragment.utf8.count)
            try await context.emitResultChunk(
                resultId: resultId,
                chunkSeq: i,
                data: fragment,
                encoding: .utf8,
                more: more
            )
            try await Task.sleep(for: .milliseconds(10))
        }
        return .streamed(
            resultId: resultId,
            size: bytes,
            summary: "report with \(total) chunks"
        )
    }
}

@main
struct ResultChunkExample {
    static func main() async throws {
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "result-chunk-demo", version: "1.0.0"),
            supportedCapabilities: Capabilities(durableJobs: true),
            auth: BearerAuthValidator(subjectsByToken: ["demo-token": "demo"])
        )
        await runtime.register(ReportBuilder())
        let server = Task { try await runtime.acceptSession(over: pair.server) }
        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "demo-token"),
            client: IdentityBlock(kind: "result-chunk-demo-client", version: "1.0.0"),
            capabilities: Capabilities(durableJobs: true)
        )

        let invoke = Envelope(
            sessionId: client.info.sessionId,
            payload: .toolInvoke(
                ToolInvokePayload(
                    tool: "report-builder",
                    arguments: .object(["chunks": .int(5)])
                )
            )
        )
        try await client.send(invoke)

        var assembler = ResultChunkAssembler()
        var chunkCount = 0
        var done = false
        for await env in client.unhandled {
            switch env.payload {
            case .jobAccepted(let p):
                print("job_id=\(p.jobId.rawValue)")
            case .jobResultChunk(let chunk):
                chunkCount += 1
                print(
                    "result_chunk seq=\(chunk.chunkSeq) more=\(chunk.more) "
                        + "len=\(chunk.data.utf8.count)B"
                )
                _ = try assembler.push(chunk)
            case .jobCompleted(let p):
                print(
                    "job.completed result_id=\(p.resultId ?? "nil") "
                        + "result_size=\(p.resultSize.map(String.init) ?? "nil") "
                        + "summary=\(p.summary ?? "nil")"
                )
                done = true
            default: break
            }
            if done { break }
        }

        let assembled = try assembler.finishUTF8()
        let preview = String(assembled.prefix(40))
        print(
            "assembled \(chunkCount) chunks into \(assembled.utf8.count) "
                + "bytes (head: \(preview))"
        )

        await client.close()
        _ = try? await server.value
    }
}
