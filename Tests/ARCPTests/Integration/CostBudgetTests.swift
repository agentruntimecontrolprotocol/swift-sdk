import Foundation
import Testing

@testable import ARCP

@Suite("cost.budget integration (ARCP v1.1 §9.6)")
struct CostBudgetTests {
    @Test("charge emits cost metric and cost.budget.remaining")
    func chargeEmitsMetrics() async throws {
        let fixture = try await IntegrationFixture(handler: ChargeTool()).open()
        defer { fixture.close() }

        async let invoked = fixture.client.invoke(
            tool: "charge",
            arguments: .null,
            costBudget: .from(["USD": 1])
        )
        var names: [String] = []
        for try await env in fixture.client.unhandled {
            if case .metric(let metric) = env.payload {
                names.append(metric.name)
                if names.count == 2 { break }
            }
        }
        let result = try await invoked
        guard case .completed = result.outcome else {
            Issue.record("expected completed, got \(result.outcome)")
            return
        }
        #expect(names.contains("cost.llm.tokens"))
        #expect(names.contains("cost.budget.remaining"))
    }

    @Test("overspend surfaces job.failed with BUDGET_EXHAUSTED")
    func overspendFailsJob() async throws {
        let fixture = try await IntegrationFixture(handler: OverspendTool()).open()
        defer { fixture.close() }

        let result = try await fixture.client.invoke(
            tool: "overspend",
            arguments: .null,
            costBudget: .from(["USD": 0.05])
        )
        guard case .failed(let error) = result.outcome else {
            Issue.record("expected failed, got \(result.outcome)")
            return
        }
        #expect(error.code == .budgetExhausted)
    }

    @Test("job without cost_budget treats charges as no-ops")
    func unbudgetedChargeNoop() async throws {
        let fixture = try await IntegrationFixture(handler: ChargeTool()).open()
        defer { fixture.close() }

        let result = try await fixture.client.invoke(tool: "charge", arguments: .null)
        guard case .completed = result.outcome else {
            Issue.record("expected completed, got \(result.outcome)")
            return
        }
    }
}

private struct ChargeTool: ToolHandler {
    let name = "charge"
    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        try await context.charge(name: "cost.llm.tokens", amount: 0.25, currency: "USD")
        return .empty
    }
}

private struct OverspendTool: ToolHandler {
    let name = "overspend"
    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        try await context.charge(name: "cost.llm.tokens", amount: 0.06, currency: "USD")
        return .empty
    }
}
