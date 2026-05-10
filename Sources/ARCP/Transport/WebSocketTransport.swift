import Foundation
import NIOCore
import NIOPosix
import WebSocketKit

/// WebSocket-backed `Transport` (client side). RFC §22.
///
/// v0.1 ships only the client transport because `WebSocketKit.WebSocket`'s
/// server-side initializer is internal. A full server transport is deferred
/// to v0.2 (see `PLAN.md` §10 / `CONFORMANCE.md`). End-to-end tests in v0.1
/// exercise the protocol stack via `MemoryTransport` and the stdio transport.
public actor WebSocketTransport: Transport {
    public nonisolated let receive: AsyncStream<Envelope>
    private let inboundContinuation: AsyncStream<Envelope>.Continuation
    private let webSocket: WebSocket
    private var closed = false

    public init(webSocket: WebSocket) {
        self.webSocket = webSocket
        var continuation: AsyncStream<Envelope>.Continuation!
        self.receive = AsyncStream { continuation = $0 }
        self.inboundContinuation = continuation
        let cont = continuation!
        webSocket.onText { _, text in
            Self.deliver(text: text, continuation: cont)
        }
        webSocket.onBinary { _, buffer in
            Self.deliver(buffer: buffer, continuation: cont)
        }
        webSocket.onClose.whenComplete { _ in
            cont.finish()
        }
    }

    public func send(_ envelope: Envelope) async throws {
        if closed {
            throw ARCPError.unavailable(reason: "websocket closed", retryAfter: nil)
        }
        let data = try envelope.toJSON()
        guard let text = String(data: data, encoding: .utf8) else {
            throw ARCPError.internal(detail: "envelope JSON not UTF-8", cause: nil)
        }
        try await webSocket.send(text)
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        try? await webSocket.close()
        inboundContinuation.finish()
    }

    private static func deliver(text: String, continuation: AsyncStream<Envelope>.Continuation) {
        guard let data = text.data(using: .utf8) else { return }
        if let envelope = try? Envelope.fromJSON(data) {
            continuation.yield(envelope)
        }
    }

    private static func deliver(
        buffer: ByteBuffer,
        continuation: AsyncStream<Envelope>.Continuation
    ) {
        var buf = buffer
        guard let data = buf.readData(length: buf.readableBytes) else { return }
        if let envelope = try? Envelope.fromJSON(data) {
            continuation.yield(envelope)
        }
    }
}

/// Convenience constructor for the *client* side of a WebSocket: connect to a
/// remote URL and yield a `WebSocketTransport` once the handshake completes.
public enum WebSocketClient {
    public static func connect(
        url: String,
        eventLoopGroup: any EventLoopGroup
    ) async throws -> WebSocketTransport {
        try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<WebSocketTransport, any Error>) in
            WebSocket.connect(to: url, on: eventLoopGroup) { ws in
                let transport = WebSocketTransport(webSocket: ws)
                cont.resume(returning: transport)
            }.whenFailure { error in
                cont.resume(throwing: error)
            }
        }
    }
}
