import ARCP
import Foundation

struct MeteredTool: ToolHandler {
    let name = "metered"

    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        try await context.charge(name: "cost.llm.tokens", amount: 0.04, currency: "USD")
        try await context.charge(name: "cost.llm.tokens", amount: 0.04, currency: "USD")
        try await context.charge(name: "cost.llm.tokens", amount: 0.04, currency: "USD")
        return .empty
    }
}

@main
struct CostBudgetExample {
    static func main() async throws {
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "cost-budget-demo", version: "1"),
            supportedCapabilities: Capabilities(costBudget: true),
            auth: BearerAuthValidator(subjectsByToken: ["demo-token": "demo"])
        )
        await runtime.register(MeteredTool())
        let server = Task { try await runtime.acceptSession(over: pair.server) }
        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "demo-token"),
            client: IdentityBlock(kind: "cost-budget-client", version: "1"),
            capabilities: Capabilities(costBudget: true)
        )

        let result = try await client.invoke(
            tool: "metered",
            arguments: .null,
            costBudget: .from(["USD": 0.10])
        )
        if case .failed(let error) = result.outcome {
            print("job.failed code=\(error.code.rawValue)")
        }

        await client.close()
        _ = try? await server.value
    }
}
