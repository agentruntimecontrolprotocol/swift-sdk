import Foundation

/// Per-session stream registry. RFC §11.
public actor StreamManager {
    public let sessionId: SessionId
    private let send: @Sendable (Envelope) async throws -> Void
    private var outbound: [StreamId: OutboundRecord] = [:]
    private var inboundContinuations: [StreamId: AsyncStream<StreamChunkPayload>.Continuation] = [:]

    public init(
        sessionId: SessionId,
        send: @escaping @Sendable (Envelope) async throws -> Void
    ) {
        self.sessionId = sessionId
        self.send = send
    }

    /// Open a new outbound stream and emit `stream.open`. Returns a handle.
    public func openOutbound(
        jobId: JobId?,
        kind: StreamKind,
        contentType: String?,
        encoding: String?
    ) async throws -> any StreamHandle {
        let streamId = StreamId.random()
        outbound[streamId] = OutboundRecord(streamId: streamId, kind: kind)
        try await send(
            Envelope(
                sessionId: sessionId,
                jobId: jobId,
                streamId: streamId,
                payload: .streamOpen(
                    StreamOpenPayload(kind: kind, contentType: contentType, encoding: encoding)
                )
            )
        )
        return ConcreteStreamHandle(
            streamId: streamId,
            sessionId: sessionId,
            jobId: jobId,
            sendEnvelope: send,
            closeHook: { [weak self] in await self?.removeOutbound(streamId) }
        )
    }

    /// Internal hook for `ConcreteStreamHandle.close` / `error`.
    func removeOutbound(_ streamId: StreamId) {
        outbound.removeValue(forKey: streamId)
    }

    /// Dispatch an inbound stream envelope (chunk/close/error) to any
    /// consumer that registered via `subscribe(streamId:)`. Phase 3 wires
    /// only the runtime side; client-side consumption is in Phase 6.
    public func dispatch(envelope: Envelope) {
        guard let streamId = envelope.streamId else { return }
        switch envelope.payload {
        case .streamChunk(let chunk):
            inboundContinuations[streamId]?.yield(chunk)
        case .streamClose, .streamError:
            inboundContinuations[streamId]?.finish()
            inboundContinuations.removeValue(forKey: streamId)
        default:
            break
        }
    }

    /// Subscribe to inbound chunks of a stream.
    public func subscribeInbound(streamId: StreamId) -> AsyncStream<StreamChunkPayload> {
        var continuation: AsyncStream<StreamChunkPayload>.Continuation!
        let stream = AsyncStream<StreamChunkPayload> { continuation = $0 }
        inboundContinuations[streamId] = continuation
        return stream
    }

    public func shutdown() async {
        for (_, continuation) in inboundContinuations {
            continuation.finish()
        }
        inboundContinuations.removeAll()
        outbound.removeAll()
    }

    private struct OutboundRecord: Sendable {
        let streamId: StreamId
        let kind: StreamKind
    }
}

struct ConcreteStreamHandle: StreamHandle, Sendable {
    let streamId: StreamId
    let sessionId: SessionId
    let jobId: JobId?
    let sendEnvelope: @Sendable (Envelope) async throws -> Void
    let closeHook: @Sendable () async -> Void

    func sendText(_ text: String, sequence: Int?) async throws {
        try await sendEnvelope(
            Envelope(
                sessionId: sessionId,
                jobId: jobId,
                streamId: streamId,
                payload: .streamChunk(StreamChunkPayload(sequence: sequence, content: text))
            )
        )
    }

    func sendChunk(_ payload: StreamChunkPayload) async throws {
        try await sendEnvelope(
            Envelope(
                sessionId: sessionId,
                jobId: jobId,
                streamId: streamId,
                payload: .streamChunk(payload)
            )
        )
    }

    func close(reason: String?) async throws {
        try await sendEnvelope(
            Envelope(
                sessionId: sessionId,
                jobId: jobId,
                streamId: streamId,
                payload: .streamClose(StreamClosePayload(reason: reason))
            )
        )
        await closeHook()
    }

    func error(_ error: ARCPError) async throws {
        try await sendEnvelope(
            Envelope(
                sessionId: sessionId,
                jobId: jobId,
                streamId: streamId,
                payload: .streamError(StreamErrorPayload(error: error.toEnvelope()))
            )
        )
        await closeHook()
    }
}
