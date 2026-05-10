/// Buffered, single-consumer mailbox of envelopes. Used internally by the
/// runtime and the client to decouple iterator consumption (a single Task
/// draining the transport) from logical receive (handshake state machines,
/// pending registries) that may need to wait, peek, or filter.
///
/// Producers call `put`; consumers call `next()`. When the producer side is
/// done it calls `finish()`; subsequent `next()` calls return `nil` once the
/// buffer is drained.
actor Mailbox<Element: Sendable> {
    private var buffer: [Element] = []
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
        if !buffer.isEmpty { return buffer.removeFirst() }
        if closed { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<Element?, Never>) in
            self.waiter = cont
        }
    }
}
