import Foundation

public final class ResultChunkStream: AsyncSequence, @unchecked Sendable {
    public typealias Element = JobResultChunkPayload

    public struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate var base: AsyncThrowingStream<Element, any Error>.Iterator

        public mutating func next() async throws -> Element? {
            try await base.next()
        }
    }

    public let resultId: String
    private let state = ResultChunkStreamState()
    private let stream: AsyncThrowingStream<Element, any Error>
    private let continuation: AsyncThrowingStream<Element, any Error>.Continuation

    public init(resultId: String = "") {
        self.resultId = resultId
        var continuation: AsyncThrowingStream<Element, any Error>.Continuation!
        self.stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    public func push(_ chunk: JobResultChunkPayload) async throws {
        do {
            try await state.push(chunk)
            continuation.yield(chunk)
        } catch {
            continuation.finish(throwing: error)
            throw error
        }
    }

    public func finish() async {
        continuation.finish()
    }

    public func fail(_ error: any Error) async {
        continuation.finish(throwing: error)
    }

    public func collect() async throws -> Data {
        for try await _ in self {}
        return try await state.finish()
    }

    public func collectUTF8() async throws -> String {
        let data = try await collect()
        guard let value = String(data: data, encoding: .utf8) else {
            throw ARCPError.dataLoss(detail: "streamed result is not valid UTF-8")
        }
        return value
    }

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
