import Foundation
import Testing

@testable import ARCP

@Suite("Idempotency semantics (issue #43)")
struct IdempotencyTests {
    @Test("Second invoke with same idempotency key returns the cached terminal")
    func duplicateInvocationReplays() async throws {
        let fixture = IntegrationFixture(handler: CountingTool())
        let open = try await fixture.open()
        defer { open.close() }

        let key = IdempotencyKey("idem_dup_test_01")

        let first = try await open.client.invoke(
            tool: "count",
            arguments: .null,
            idempotencyKey: key
        )
        guard case .completed(let firstPayload) = first.outcome else {
            Issue.record("first invocation did not complete")
            return
        }
        let firstResult = firstPayload.result ?? .null

        let second = try await open.client.invoke(
            tool: "count",
            arguments: .null,
            idempotencyKey: key
        )
        guard case .completed(let secondPayload) = second.outcome else {
            Issue.record("second invocation did not complete")
            return
        }
        // Same handler-produced result re-delivered; the handler must not have
        // executed twice. CountingTool's actor exposes the call count.
        #expect(secondPayload.result == firstResult)
        #expect(first.jobId == second.jobId)
        let count = await CountingTool.callCount
        #expect(count == 1)
    }
}

private struct CountingTool: ToolHandler {
    static let counter = AtomicCounter()
    static var callCount: Int { get async { await counter.value } }

    let name = "count"
    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        let next = await Self.counter.increment()
        return .value(.int(Int64(next)))
    }
}

private actor AtomicCounter {
    private(set) var value: Int = 0
    @discardableResult
    func increment() -> Int {
        value += 1
        return value
    }
}
