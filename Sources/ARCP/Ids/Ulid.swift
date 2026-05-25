import Foundation

/// Crockford-base32 [ULID](https://github.com/ulid/spec) generator used for every
/// SDK-minted id (messages, sessions, jobs, streams, ...).
///
/// ULIDs sort lexicographically by creation time, which makes them the natural
/// row key for the SQLite event log (RFC §19) and for filter-aware backfill
/// (RFC §13.3). The implementation enforces strict monotonicity within a
/// single process: if two ULIDs share a millisecond, the second's random tail
/// is the first's random tail incremented.
public enum Ulid {
    /// 26-character ULID. Safe to call from any actor.
    public static func next() -> String {
        Self.generator.next()
    }

    private static let generator = MonotonicGenerator()
}

/// Thread-safe (lock-isolated) monotonic ULID generator. Uses `NSLock` for the
/// minimum critical section because no actor isolation is appropriate here —
/// `Ulid.next()` must be callable from any sync context including module init.
private final class MonotonicGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTime: UInt64 = 0
    private var lastRandom: [UInt8] = Array(repeating: 0, count: 10)

    func next() -> String {
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        lock.lock()
        defer { lock.unlock() }
        var random = [UInt8](repeating: 0, count: 10)
        var timeMs: UInt64
        if nowMs > lastTime {
            // System clock advanced — start a fresh random tail.
            timeMs = nowMs
            for index in 0..<10 {
                random[index] = UInt8.random(in: 0...255)
            }
        } else {
            // Clock equals or moved backwards. Hold the previous timestamp
            // and increment the previous random tail so the new id sorts
            // strictly after the last one. RFC §6.2 monotonicity.
            timeMs = lastTime
            random = lastRandom
            if !increment(&random) {
                // Tail overflowed. Advance the timestamp by one millisecond
                // and restart the tail with a fresh random value so we never
                // emit an id with a lower-or-equal sort key under the same
                // timestamp.
                timeMs = lastTime &+ 1
                for index in 0..<10 {
                    random[index] = UInt8.random(in: 0...255)
                }
            }
        }
        lastTime = timeMs
        lastRandom = random
        return encode(time: timeMs, random: random)
    }

    /// Increment `bytes` as a big-endian integer. Returns `false` when the
    /// value overflowed (all bytes were `0xFF`), `true` otherwise.
    private func increment(_ bytes: inout [UInt8]) -> Bool {
        for index in (0..<bytes.count).reversed() {
            if bytes[index] < 0xFF {
                bytes[index] &+= 1
                return true
            }
            bytes[index] = 0
        }
        return false
    }

    private func encode(time: UInt64, random: [UInt8]) -> String {
        var output = [Character]()
        output.reserveCapacity(26)
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        for shift in stride(from: 45, through: 0, by: -5) {
            let value = Int((time >> shift) & 0x1F)
            output.append(alphabet[value])
        }
        let bits = random.flatMap { byte -> [Int] in
            (0..<8).map { Int((byte >> (7 - $0)) & 0x01) }
        }
        var idx = 0
        while idx + 4 < bits.count {
            var value = 0
            for j in 0..<5 {
                value = (value << 1) | bits[idx + j]
            }
            output.append(alphabet[value])
            idx += 5
        }
        return String(output)
    }
}
