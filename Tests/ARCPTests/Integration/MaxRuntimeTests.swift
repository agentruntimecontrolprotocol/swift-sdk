import Foundation
import Testing

@testable import ARCP

@Suite("max_runtime_sec / timed_out (ARCP v1.1 §7.1, §7.3)")
struct MaxRuntimeTests {
    @Test("Exceeding max_runtime_sec terminates the job with TIMEOUT")
    func runtimeDeadlineFires() async throws {
        let fixture = try await IntegrationFixture(handler: SlowForeverTool()).open()
        defer { fixture.close() }

        let result = try await fixture.client.invoke(
            tool: "slow",
            arguments: .null,
            maxRuntimeSec: 1
        )
        guard case .failed(let error) = result.outcome else {
            Issue.record("expected failed (timeout), got \(result.outcome)")
            return
        }
        #expect(error.code == .timeout)
    }

    @Test("A fast job under the deadline completes normally")
    func underDeadlineCompletes() async throws {
        let fixture = try await IntegrationFixture(handler: FastTool()).open()
        defer { fixture.close() }

        let result = try await fixture.client.invoke(
            tool: "fast",
            arguments: .null,
            maxRuntimeSec: 30
        )
        guard case .completed = result.outcome else {
            Issue.record("expected completed, got \(result.outcome)")
            return
        }
    }
}

private struct SlowForeverTool: ToolHandler {
    let name = "slow"
    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        // Cooperatively observe cancellation so the deadline can stop us.
        for _ in 0..<200 {
            try await context.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }
        return .empty
    }
}

private struct FastTool: ToolHandler {
    let name = "fast"
    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        .value(.string("done"))
    }
}
