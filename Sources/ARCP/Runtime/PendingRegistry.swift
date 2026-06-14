import Foundation

/// Generic register-and-await primitive for request/response envelopes.
/// RFC §6.1 (`correlation_id`).
///
/// Usage: register a `MessageId` to await, then someone resolves the same id
/// (typically from the dispatch loop) to deliver the response. A separate
/// timeout deadline races each pending await; if the deadline elapses first,
/// the awaiter sees `ARCPError.deadlineExceeded`.
public actor PendingRegistry<Response: Sendable> {
    private enum Slot {
        case pending
        case waiting(CheckedContinuation<Response, any Error>)
        case readyValue(Response)
        case readyError(any Error)
    }

    private var slots: [MessageId: Slot] = [:]

    public init() {}

    /// Register a waiter for `id` and return its response when it arrives or
    /// `ARCPError.deadlineExceeded` when `deadline` elapses first.
    public func awaitResponse(id: MessageId, deadline: Duration) async throws -> Response {
        // Reject a duplicate registration so we never overwrite (and orphan)
        // an existing waiter's continuation for the same id.
        if slots[id] != nil {
            throw ARCPError.internal(detail: "duplicate pending response \(id)", cause: nil)
        }
        slots[id] = .pending
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: deadline)
            if Task.isCancelled { return }
            await self?.dropForTimeout(id: id)
        }
        defer { timeoutTask.cancel() }
        return try await suspend(id: id)
    }

    /// Resolve a pending await with a value. Returns `true` if a waiter was
    /// found and resumed.
    @discardableResult
    public func resolve(id: MessageId, value: Response) -> Bool {
        guard let slot = slots[id] else { return false }
        switch slot {
        case .pending:
            slots[id] = .readyValue(value)
            return true
        case .waiting(let cont):
            slots.removeValue(forKey: id)
            cont.resume(returning: value)
            return true
        case .readyValue, .readyError:
            return false
        }
    }

    /// Resolve a pending await with an error.
    @discardableResult
    public func reject(id: MessageId, error: any Error) -> Bool {
        guard let slot = slots[id] else { return false }
        switch slot {
        case .pending:
            slots[id] = .readyError(error)
            return true
        case .waiting(let cont):
            slots.removeValue(forKey: id)
            cont.resume(throwing: error)
            return true
        case .readyValue, .readyError:
            return false
        }
    }

    /// Cancel any in-flight pending request — used by external callers (e.g.
    /// session shutdown) to forcibly fail an awaiter.
    func cancel(id: MessageId) {
        _ = reject(id: id, error: ARCPError.cancelled(operation: "pending \(id)", reason: "cancelled"))
    }

    /// Quietly drop a waiter without delivering a response. Used by the
    /// deadline race so the deadline task's throw is the one that surfaces.
    func dropForTimeout(id: MessageId) {
        _ = reject(id: id, error: ARCPError.deadlineExceeded(operation: "pending response \(id)"))
    }

    /// Reject every pending awaiter — called when the session ends.
    public func failAll(error: any Error) {
        let snapshot = slots
        slots.removeAll()
        for (_, slot) in snapshot {
            if case .waiting(let cont) = slot {
                cont.resume(throwing: error)
            }
        }
    }

    private func suspend(id: MessageId) async throws -> Response {
        try await withCheckedThrowingContinuation { cont in
            switch slots[id] {
            case .readyValue(let value):
                slots.removeValue(forKey: id)
                cont.resume(returning: value)
            case .readyError(let err):
                slots.removeValue(forKey: id)
                cont.resume(throwing: err)
            case .pending, .none:
                slots[id] = .waiting(cont)
            case .waiting:
                cont.resume(throwing: ARCPError.internal(detail: "double-attach pending \(id)", cause: nil))
            }
        }
    }
}
