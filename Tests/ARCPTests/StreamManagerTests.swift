import Foundation
import Testing

@testable import ARCP

@Suite("StreamManager")
struct StreamManagerTests {
    @Test("outbound handle emits open, chunk, close, and error envelopes")
    func outboundHandleEmitsLifecycle() async throws {
        let sink = EnvelopeSink()
        let manager = StreamManager(sessionId: SessionId("sess_stream"), send: { envelope in
            await sink.append(envelope)
        })
        let handle = try await manager.openOutbound(
            jobId: JobId("job_stream"),
            kind: .text,
            contentType: "text/plain",
            encoding: "utf-8"
        )
        try await handle.sendText("hello", sequence: 1)
        try await handle.sendChunk(StreamChunkPayload(sequence: 2, content: "world"))
        try await handle.close(reason: "done")
        let second = try await manager.openOutbound(
            jobId: nil,
            kind: .event,
            contentType: nil,
            encoding: nil
        )
        try await second.error(.internal(detail: "boom", cause: nil))

        let payloads = await sink.payloads()
        #expect(payloads.map(\.typeName) == [
            "stream.open",
            "stream.chunk",
            "stream.chunk",
            "stream.close",
            "stream.open",
            "stream.error",
        ])
    }

    @Test("inbound subscription receives chunks and finishes on close")
    func inboundSubscriptionLifecycle() async throws {
        let manager = StreamManager(sessionId: SessionId("sess_stream"), send: { _ in })
        let streamId = StreamId("stream_in")
        let stream = try await manager.subscribeInbound(streamId: streamId)
        var iterator = stream.makeAsyncIterator()

        await manager.dispatch(
            envelope: Envelope(
                streamId: streamId,
                payload: .streamChunk(StreamChunkPayload(sequence: 1, content: "one"))
            )
        )
        let first = await iterator.next()
        #expect(first?.content == "one")

        await manager.dispatch(
            envelope: Envelope(streamId: streamId, payload: .streamClose(StreamClosePayload()))
        )
        let ended = await iterator.next()
        #expect(ended == nil)
    }

    @Test("duplicate inbound subscription throws failedPrecondition")
    func duplicateInboundSubscription() async throws {
        let manager = StreamManager(sessionId: SessionId("sess_stream"), send: { _ in })
        let streamId = StreamId("stream_dupe")
        _ = try await manager.subscribeInbound(streamId: streamId)
        await #expect(throws: ARCPError.self) {
            _ = try await manager.subscribeInbound(streamId: streamId)
        }
    }

    @Test("shutdown finishes active inbound streams")
    func shutdownFinishesInboundStreams() async throws {
        let manager = StreamManager(sessionId: SessionId("sess_stream"), send: { _ in })
        let stream = try await manager.subscribeInbound(streamId: StreamId("stream_shutdown"))
        var iterator = stream.makeAsyncIterator()
        await manager.shutdown()
        #expect(await iterator.next() == nil)
    }
}

actor EnvelopeSink {
    private var envelopes: [Envelope] = []

    func append(_ envelope: Envelope) {
        envelopes.append(envelope)
    }

    func payloads() -> [MessageType] {
        envelopes.map(\.payload)
    }

    func all() -> [Envelope] {
        envelopes
    }
}
