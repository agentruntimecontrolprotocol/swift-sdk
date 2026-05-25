/// Buffered, single-consumer mailbox of envelopes. Used internally by the
/// runtime and the client to decouple iterator consumption (a single Task
/// draining the transport) from logical receive (handshake state machines,
/// pending registries) that may need to wait, peek, or filter.
///
/// Producers call `put`; consumers call `next()`. When the producer side is
/// done it calls `finish()`; subsequent `next()` calls return `nil` once the
/// buffer is drained.
///
/// The buffer uses a head index with periodic compaction so draining N
/// envelopes is O(N) total rather than O(N²). `Array.removeFirst()` shifts
/// the remaining elements, which made bursty resume / subscription replay
/// quadratic.
actor Mailbox<Element: Sendable> {
    private var buffer: [Element] = []
    private var head: Int = 0
    private var waiter: CheckedContinuation<Element?, Never>?
    private var closed = false

    func put(_ value: Element) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: value)
        } else {
            buffer.append(value)
        }
    }

    func finish() {
        guard !closed else { return }
        closed = true
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: nil)
        }
    }

    /// Wait for the next element, or `nil` if the producer has finished and
    /// the buffer is empty. Multiple concurrent waiters are not supported —
    /// the mailbox is single-consumer.
    func next() async -> Element? {
        if head < buffer.count {
            let value = buffer[head]
            head += 1
            compactIfNeeded()
            return value
        }
        if closed { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<Element?, Never>) in
            self.waiter = cont
        }
    }

    private func compactIfNeeded() {
        // Compact when the dead prefix is at least half of the array AND not
        // tiny. This keeps amortized work O(1) per element while bounding the
        // wasted prefix to roughly the live tail.
        if head >= 64 && head >= buffer.count / 2 {
            buffer.removeFirst(head)
            head = 0
        }
    }
}
