import Foundation
import Testing

@testable import ARCP

@Suite("ResultChunkStream integration (ARCP v1.1 §8.4)")
struct ResultChunkStreamTests {
    @Test("client AsyncSequence yields chunks and collectUTF8 reassembles result")
    func streamCollectsUTF8() async throws {
        let fixture = try await IntegrationFixture(
            handler: DelayedStreamingTool(),
            capabilities: Capabilities(resultChunk: true)
        ).open(capabilities: Capabilities(resultChunk: true))
        defer { fixture.close() }

        try await fixture.client.send(
            Envelope(
                sessionId: fixture.client.info.sessionId,
                payload: .toolInvoke(ToolInvokePayload(tool: "stream-delayed", arguments: .null))
            )
        )
        let accepted = try await fixture.next { if case .jobAccepted = $0.payload { true } else { false } }
        let jobId = try #require(accepted.jobId)
        let stream = await fixture.client.resultChunks(for: jobId)
        let value = try await stream.collectUTF8()
        #expect(value == "alpha-beta")
    }
}

private struct DelayedStreamingTool: ToolHandler {
    let name = "stream-delayed"
    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        try await Task.sleep(for: .milliseconds(100))
        let resultId = "res_\(invocation.jobId.rawValue)"
        try await context.emitResultChunk(
            resultId: resultId, chunkSeq: 0, data: "alpha", encoding: .utf8, more: true)
        try await context.emitResultChunk(
            resultId: resultId, chunkSeq: 1, data: "-beta", encoding: .utf8, more: false)
        return .streamed(resultId: resultId, size: 10, summary: "joined")
    }
}
