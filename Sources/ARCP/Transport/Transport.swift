/// Bidirectional channel that carries `Envelope` values in both directions.
/// RFC §22.
///
/// Implementations must be `Sendable` and safe to drive from a single actor.
/// `receive` yields envelopes in arrival order; the stream completes when the
/// peer closes the channel or `close()` is invoked locally.
public protocol Transport: Sendable {
    /// Send an envelope to the remote peer.
    func send(_ envelope: Envelope) async throws

    /// Async sequence of incoming envelopes.
    var receive: AsyncStream<Envelope> { get }

    /// Close the channel. Idempotent.
    func close() async
}
