import Foundation

/// Generic register-and-await primitive for request/response envelopes.
/// RFC §6.1 (`correlation_id`).
///
/// Usage: register a `MessageId` to await, then someone resolves the same id
/// (typically from the dispatch loop) to deliver the response. A separate
/// timeout deadline races each pending await; if the deadline elapses first,
/// the awaiter sees `ARCPError.deadlineExceeded`.
public actor PendingRegistry<Response: Sendable> {
    private var waiters: [MessageId: CheckedContinuation<Response, any Error>] = [:]

    public init() {}

    /// Register a waiter for `id` and return its response when it arrives or
    /// `ARCPError.deadlineExceeded` when `deadline` elapses first.
    public func awaitResponse(id: MessageId, deadline: Duration) async throws -> Response {
        try await withThrowingTaskGroup(of: Response.self) { group in
            group.addTask {
                try await self.suspend(id: id)
            }
            group.addTask { [weak self] in
                try await Task.sleep(for: deadline)
                await self?.cancel(id: id)
                throw ARCPError.deadlineExceeded(operation: "pending response \(id)")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw ARCPError.internal(detail: "pending registry empty", cause: nil)
            }
            return result
        }
    }

    /// Resolve a pending await with a value. Returns `true` if a waiter was
    /// found and resumed.
    @discardableResult
    public func resolve(id: MessageId, value: Response) -> Bool {
        guard let cont = waiters.removeValue(forKey: id) else { return false }
        cont.resume(returning: value)
        return true
    }

    /// Resolve a pending await with an error.
    @discardableResult
    public func reject(id: MessageId, error: any Error) -> Bool {
        guard let cont = waiters.removeValue(forKey: id) else { return false }
        cont.resume(throwing: error)
        return true
    }

    /// Cancel any in-flight pending request — used internally by the deadline race.
    func cancel(id: MessageId) {
        guard let cont = waiters.removeValue(forKey: id) else { return }
        cont.resume(throwing: ARCPError.cancelled(operation: "pending \(id)", reason: "deadline"))
    }

    /// Reject every pending awaiter — called when the session ends.
    public func failAll(error: any Error) {
        for (_, cont) in waiters {
            cont.resume(throwing: error)
        }
        waiters.removeAll()
    }

    private func suspend(id: MessageId) async throws -> Response {
        try await withCheckedThrowingContinuation { cont in
            waiters[id] = cont
        }
    }
}
