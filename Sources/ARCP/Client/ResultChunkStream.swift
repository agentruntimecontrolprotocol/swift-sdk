import Foundation

/// Typed async sequence of `job.result_chunk` payloads for a single job.
///
/// Returned by `ARCPClient.resultChunks(for:)` and (on the runtime side)
/// produced as part of result-chunk delivery. The stream completes when the
/// job reaches its terminal envelope or when `finish()`/`fail(_:)` is called.
public final class ResultChunkStream: AsyncSequence, @unchecked Sendable {
    /// The element type yielded by the sequence — one `job.result_chunk` payload.
    public typealias Element = JobResultChunkPayload

    /// Iterator over the underlying throwing async stream of result chunks.
    public struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate var base: AsyncThrowingStream<Element, any Error>.Iterator

        /// Advance the iterator. Throws if the stream was failed.
        public mutating func next() async throws -> Element? {
            try await base.next()
        }
    }

    /// Logical result identifier carried by the chunks (RFC §8.4).
    public let resultId: String
    private let state = ResultChunkStreamState()
    private let stream: AsyncThrowingStream<Element, any Error>
    private let continuation: AsyncThrowingStream<Element, any Error>.Continuation

    /// Create a new stream optionally tagged with a `resultId`.
    public init(resultId: String = "") {
        self.resultId = resultId
        var continuation: AsyncThrowingStream<Element, any Error>.Continuation!
        self.stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    /// Push a chunk through the underlying assembler and yield it to subscribers.
    ///
    /// - Parameter chunk: Chunk to deliver.
    /// - Throws: Rethrows any assembler error after failing the stream.
    public func push(_ chunk: JobResultChunkPayload) async throws {
        do {
            try await state.push(chunk)
            continuation.yield(chunk)
        } catch {
            continuation.finish(throwing: error)
            throw error
        }
    }

    /// Finish the stream gracefully. Subsequent iterators return `nil`.
    public func finish() async {
        continuation.finish()
    }

    /// Finish the stream with an error. Subsequent iterators rethrow it.
    public func fail(_ error: any Error) async {
        continuation.finish(throwing: error)
    }

    /// Drain the stream to completion and return the assembled bytes.
    ///
    /// - Returns: The fully assembled result bytes.
    /// - Throws: Any assembler error or upstream failure.
    public func collect() async throws -> Data {
        for try await _ in self {}
        return try await state.finish()
    }

    /// Drain the stream and return the assembled bytes as a UTF-8 string.
    ///
    /// - Throws: `ARCPError.dataLoss` if the bytes are not valid UTF-8.
    public func collectUTF8() async throws -> String {
        let data = try await collect()
        guard let value = String(data: data, encoding: .utf8) else {
            throw ARCPError.dataLoss(detail: "streamed result is not valid UTF-8")
        }
        return value
    }

    /// Conform to `AsyncSequence`.
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: stream.makeAsyncIterator())
    }
}

private actor ResultChunkStreamState {
    private var assembler = ResultChunkAssembler()

    func push(_ chunk: JobResultChunkPayload) throws {
        _ = try assembler.push(chunk)
    }

    func finish() throws -> Data {
        try assembler.finish()
    }
}
