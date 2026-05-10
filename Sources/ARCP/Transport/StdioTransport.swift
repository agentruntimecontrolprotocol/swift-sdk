import Foundation

/// Newline-delimited JSON transport over a pair of `FileHandle`s. RFC §22.
///
/// Inbound bytes are consumed via `readabilityHandler`, which dispatches
/// chunks asynchronously and is cleanly torn down on `close()` — no
/// blocking-read thread to abort.
public actor StdioTransport: Transport {
    public nonisolated let receive: AsyncStream<Envelope>
    private let inboundContinuation: AsyncStream<Envelope>.Continuation
    private let outbound: FileHandle
    private let inbound: FileHandle
    private nonisolated(unsafe) var buffer = Data()
    private var closed = false

    public init(inbound: FileHandle = .standardInput, outbound: FileHandle = .standardOutput) {
        self.inbound = inbound
        self.outbound = outbound
        var continuation: AsyncStream<Envelope>.Continuation!
        self.receive = AsyncStream { continuation = $0 }
        self.inboundContinuation = continuation

        let cont = continuation!
        let bufferRef = BufferRef()
        let decoder = Envelope.makeDecoder()
        inbound.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                if !bufferRef.data.isEmpty,
                    let envelope = try? decoder.decode(Envelope.self, from: bufferRef.data)
                {
                    cont.yield(envelope)
                }
                cont.finish()
                handle.readabilityHandler = nil
                return
            }
            bufferRef.data.append(chunk)
            while let newlineIndex = bufferRef.data.firstIndex(of: 0x0A) {
                let line = bufferRef.data.prefix(upTo: newlineIndex)
                bufferRef.data.removeSubrange(bufferRef.data.startIndex...newlineIndex)
                guard !line.isEmpty else { continue }
                if let envelope = try? decoder.decode(Envelope.self, from: line) {
                    cont.yield(envelope)
                }
            }
        }
    }

    public func send(_ envelope: Envelope) async throws {
        if closed {
            throw ARCPError.unavailable(reason: "stdio transport closed", retryAfter: nil)
        }
        let data = try envelope.toJSON()
        try outbound.write(contentsOf: data)
        try outbound.write(contentsOf: Data([0x0A]))
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        inbound.readabilityHandler = nil
        try? inbound.close()
        try? outbound.close()
        inboundContinuation.finish()
    }
}

/// Reference cell so the readabilityHandler closure (captured by-value) can
/// share a single mutating buffer.
private final class BufferRef: @unchecked Sendable {
    var data = Data()
}
