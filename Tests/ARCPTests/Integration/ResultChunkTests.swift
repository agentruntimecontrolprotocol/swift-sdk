import Foundation
import Testing

@testable import ARCP

@Suite("job.result_chunk (ARCP v1.1 §8.4)")
struct ResultChunkTests {
    @Test("JobResultChunkPayload Codable round-trip uses spec wire keys")
    func payloadRoundTrip() throws {
        let payload = JobResultChunkPayload(
            resultId: "res_abc",
            chunkSeq: 3,
            data: "hello",
            encoding: .utf8,
            more: true
        )
        let encoded = try JSONEncoder().encode(payload)
        guard
            let obj = try JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        else {
            Issue.record("not a JSON object")
            return
        }
        #expect(obj["result_id"] as? String == "res_abc")
        #expect(obj["chunk_seq"] as? Int == 3)
        #expect(obj["data"] as? String == "hello")
        #expect(obj["encoding"] as? String == "utf8")
        #expect(obj["more"] as? Bool == true)
        let back = try JSONDecoder().decode(JobResultChunkPayload.self, from: encoded)
        #expect(back == payload)
    }

    @Test("JobCompletedPayload carries result_id / result_size / summary markers")
    func completedCarriesStreamMarkers() throws {
        let payload = JobCompletedPayload(
            resultId: "res_x",
            resultSize: 1024,
            summary: "report"
        )
        let encoded = try JSONEncoder().encode(payload)
        guard
            let obj = try JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        else {
            Issue.record("not a JSON object")
            return
        }
        #expect(obj["result_id"] as? String == "res_x")
        #expect(obj["result_size"] as? Int == 1024)
        #expect(obj["summary"] as? String == "report")
        // No inline result when streamed.
        #expect(obj["result"] == nil)
    }

    @Test("Assembler concatenates UTF-8 chunks until terminal")
    func assemblerUTF8() throws {
        var asm = ResultChunkAssembler()
        try asm.push(
            JobResultChunkPayload(
                resultId: "r", chunkSeq: 0, data: "foo", encoding: .utf8, more: true
            )
        )
        try asm.push(
            JobResultChunkPayload(
                resultId: "r", chunkSeq: 1, data: "bar", encoding: .utf8, more: false
            )
        )
        #expect(asm.isFinished)
        #expect(try asm.finishUTF8() == "foobar")
    }

    @Test("Assembler reassembles base64 binary payloads")
    func assemblerBase64() throws {
        var asm = ResultChunkAssembler()
        // "hello world" → "aGVsbG8gd29ybGQ="
        let part1 = Data("hello ".utf8).base64EncodedString()
        let part2 = Data("world".utf8).base64EncodedString()
        try asm.push(
            JobResultChunkPayload(
                resultId: "r", chunkSeq: 0, data: part1, encoding: .base64, more: true
            )
        )
        try asm.push(
            JobResultChunkPayload(
                resultId: "r", chunkSeq: 1, data: part2, encoding: .base64, more: false
            )
        )
        let bytes = try asm.finish()
        #expect(String(data: bytes, encoding: .utf8) == "hello world")
    }

    @Test("Out-of-order chunks raise outOfOrder")
    func assemblerRejectsOutOfOrder() throws {
        var asm = ResultChunkAssembler()
        try asm.push(
            JobResultChunkPayload(
                resultId: "r", chunkSeq: 0, data: "a", encoding: .utf8, more: true
            )
        )
        let chunk = JobResultChunkPayload(
            resultId: "r", chunkSeq: 2, data: "b", encoding: .utf8, more: false
        )
        #expect(throws: ResultChunkError.self) {
            try asm.push(chunk)
        }
    }

    @Test("Mismatched encoding raises encodingMismatch")
    func assemblerRejectsEncodingChange() throws {
        var asm = ResultChunkAssembler()
        try asm.push(
            JobResultChunkPayload(
                resultId: "r", chunkSeq: 0, data: "a", encoding: .utf8, more: true
            )
        )
        let chunk = JobResultChunkPayload(
            resultId: "r", chunkSeq: 1, data: "Yg==", encoding: .base64, more: false
        )
        #expect(throws: ResultChunkError.self) {
            try asm.push(chunk)
        }
    }

    @Test("End-to-end: streaming agent reassembles via client")
    func endToEnd() async throws {
        struct StreamingTool: ToolHandler {
            let name = "streamer"
            func execute(
                invocation: ToolInvocation,
                context: any JobContext
            ) async throws -> ToolOutput {
                let rid = "res_\(invocation.jobId.rawValue)"
                let parts = ["alpha", "-beta", "-gamma"]
                var size: UInt64 = 0
                for (i, part) in parts.enumerated() {
                    size += UInt64(part.utf8.count)
                    try await context.emitResultChunk(
                        resultId: rid,
                        chunkSeq: UInt64(i),
                        data: part,
                        encoding: .utf8,
                        more: i + 1 < parts.count
                    )
                }
                return .streamed(resultId: rid, size: size, summary: "joined")
            }
        }

        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "result-chunk-test", version: "1"),
            supportedCapabilities: Capabilities(durableJobs: true),
            auth: BearerAuthValidator(subjectsByToken: ["t": "alice"])
        )
        await runtime.register(StreamingTool())
        let serverTask = Task { try await runtime.acceptSession(over: pair.server) }
        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "t"),
            client: IdentityBlock(kind: "result-chunk-client", version: "1"),
            capabilities: Capabilities(durableJobs: true)
        )
        defer {
            Task {
                await client.close()
                _ = try? await serverTask.value
            }
        }

        let invoke = Envelope(
            sessionId: client.info.sessionId,
            payload: .toolInvoke(
                ToolInvokePayload(tool: "streamer", arguments: .null)
            )
        )
        try await client.send(invoke)

        var asm = ResultChunkAssembler()
        var completed: JobCompletedPayload?
        let deadline = Date(timeIntervalSinceNow: 2.0)
        for await env in client.unhandled {
            if Date() > deadline { break }
            switch env.payload {
            case .jobResultChunk(let chunk):
                _ = try asm.push(chunk)
            case .jobCompleted(let p):
                completed = p
            default:
                break
            }
            if completed != nil { break }
        }
        let result = try #require(completed)
        #expect(result.resultId?.hasPrefix("res_") == true)
        #expect(result.summary == "joined")
        #expect(result.result == nil)
        #expect(try asm.finishUTF8() == "alpha-beta-gamma")
    }
}
