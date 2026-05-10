/// Paired in-memory transports used heavily by integration tests. Each call
/// to `MemoryTransport.makePair()` returns two `MemoryTransport` instances
/// linked so that envelopes sent via one are received by the other.
public final class MemoryTransport: Transport, @unchecked Sendable {
    // @unchecked Sendable: the only mutable state is the AsyncStream
    // continuation, which is itself Sendable, plus a closed flag protected by
    // the inbound stream's serialized continuation. All public surface flows
    // through `Sendable`-checked types.
    private let inboundContinuation: AsyncStream<Envelope>.Continuation
    public let receive: AsyncStream<Envelope>
    private let peer: PeerHandle

    private final class PeerHandle: @unchecked Sendable {
        var send: ((Envelope) -> Void)?
        var close: (() -> Void)?
    }

    private init(peer: PeerHandle) {
        var continuation: AsyncStream<Envelope>.Continuation!
        self.receive = AsyncStream { continuation = $0 }
        self.inboundContinuation = continuation
        self.peer = peer
    }

    public static func makePair() -> (client: MemoryTransport, server: MemoryTransport) {
        let clientPeer = PeerHandle()
        let serverPeer = PeerHandle()
        let client = MemoryTransport(peer: serverPeer)
        let server = MemoryTransport(peer: clientPeer)
        // Sending through `client.peer` (which is serverPeer) yields into server.
        serverPeer.send = { [weak server] envelope in server?.inboundContinuation.yield(envelope) }
        serverPeer.close = { [weak server] in server?.inboundContinuation.finish() }
        clientPeer.send = { [weak client] envelope in client?.inboundContinuation.yield(envelope) }
        clientPeer.close = { [weak client] in client?.inboundContinuation.finish() }
        return (client, server)
    }

    public func send(_ envelope: Envelope) async throws {
        peer.send?(envelope)
    }

    public func close() async {
        inboundContinuation.finish()
        peer.close?()
    }
}
