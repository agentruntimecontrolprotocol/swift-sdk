import Foundation
import Testing

@testable import ARCP

@Suite("PendingRegistry race-safety (issue #42)")
struct PendingRegistryTests {
    @Test("resolve delivered after suspend wins over deadline")
    func resolveAfterSuspend() async throws {
        let registry = PendingRegistry<Int>()
        let id = MessageId.random()
        Task {
            // Delay slightly to ensure awaitResponse has suspended.
            try? await Task.sleep(for: .milliseconds(20))
            _ = await registry.resolve(id: id, value: 99)
        }
        let value = try await registry.awaitResponse(id: id, deadline: .seconds(2))
        #expect(value == 99)
    }

    @Test("timeout fails the waiter")
    func timeoutFails() async {
        let registry = PendingRegistry<Int>()
        let id = MessageId.random()
        await #expect(throws: ARCPError.self) {
            _ = try await registry.awaitResponse(id: id, deadline: .milliseconds(50))
        }
    }

    @Test("reject delivered after suspend resumes with error")
    func rejectAfterSuspend() async {
        let registry = PendingRegistry<Int>()
        let id = MessageId.random()
        Task {
            // Small delay so awaitResponse has a chance to suspend.
            try? await Task.sleep(for: .milliseconds(20))
            _ = await registry.reject(id: id, error: ARCPError.notFound(kind: "x", id: id.rawValue))
        }
        await #expect(throws: ARCPError.self) {
            _ = try await registry.awaitResponse(id: id, deadline: .seconds(2))
        }
    }
}
