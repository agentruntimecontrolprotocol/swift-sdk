import Foundation

/// Errors returned by ``ResultChunkAssembler/push(_:)`` and
/// ``ResultChunkAssembler/finish()``.
public enum ResultChunkError: Error, Sendable, Equatable {
    /// A chunk arrived with a `chunkSeq` that did not match the next
    /// expected sequence.
    case outOfOrder(expected: UInt64, got: UInt64)
    /// A chunk's `resultId` differs from previously buffered chunks.
    case resultIdMismatch(expected: String, got: String)
    /// A chunk's `encoding` differs from previously buffered chunks.
    case encodingMismatch(expected: ResultChunkEncoding, got: ResultChunkEncoding)
    /// A base64 fragment failed to decode.
    case base64Decode(seq: UInt64)
    /// More chunks were pushed after a terminal `more: false`.
    case afterFinal
    /// `finish` called before any terminal chunk arrived.
    case notFinal
}

/// Helper that accumulates ``JobResultChunkPayload`` fragments for a
/// single `resultId` and assembles the final payload when `more: false`
/// arrives (ARCP v1.1 §8.4).
///
/// Chunks must be supplied in `chunkSeq` order — out-of-order chunks
/// surface as ``ResultChunkError/outOfOrder(expected:got:)``. Mixing
/// encodings for the same `resultId` surfaces as
/// ``ResultChunkError/encodingMismatch(expected:got:)``.
public struct ResultChunkAssembler: Sendable {
    private var resultIdState: String?
    private var encodingState: ResultChunkEncoding?
    private var nextSeq: UInt64 = 0
    private var buffer: [UInt8] = []
    private var finished: Bool = false

    public init() {}

    /// Append `chunk`. Returns `true` if this chunk was terminal
    /// (`more: false`), `false` otherwise.
    @discardableResult
    public mutating func push(_ chunk: JobResultChunkPayload) throws -> Bool {
        if finished {
            throw ResultChunkError.afterFinal
        }
        if chunk.chunkSeq != nextSeq {
            throw ResultChunkError.outOfOrder(expected: nextSeq, got: chunk.chunkSeq)
        }
        if let rid = resultIdState {
            if rid != chunk.resultId {
                throw ResultChunkError.resultIdMismatch(expected: rid, got: chunk.resultId)
            }
        } else {
            resultIdState = chunk.resultId
        }
        if let enc = encodingState {
            if enc != chunk.encoding {
                throw ResultChunkError.encodingMismatch(expected: enc, got: chunk.encoding)
            }
        } else {
            encodingState = chunk.encoding
        }
        switch chunk.encoding {
        case .utf8:
            buffer.append(contentsOf: Array(chunk.data.utf8))
        case .base64:
            guard let decoded = Data(base64Encoded: chunk.data) else {
                throw ResultChunkError.base64Decode(seq: chunk.chunkSeq)
            }
            buffer.append(contentsOf: decoded)
        }
        nextSeq &+= 1
        if !chunk.more {
            finished = true
        }
        return !chunk.more
    }

    /// True once a terminal chunk has been pushed.
    public var isFinished: Bool { finished }

    /// The selected encoding, if any chunks have arrived.
    public var encoding: ResultChunkEncoding? { encodingState }

    /// The `resultId` of the buffered stream, if any chunks have arrived.
    public var resultId: String? { resultIdState }

    /// Consume the assembler and return the assembled bytes.
    public func finish() throws -> Data {
        if !finished {
            throw ResultChunkError.notFinal
        }
        return Data(buffer)
    }

    /// Consume the assembler and decode the buffer as UTF-8.
    public func finishUTF8() throws -> String {
        let bytes = try finish()
        guard let s = String(data: bytes, encoding: .utf8) else {
            throw ResultChunkError.base64Decode(seq: UInt64.max)
        }
        return s
    }
}
