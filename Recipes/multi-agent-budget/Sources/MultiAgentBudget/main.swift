/// Recipe: Multi-Agent Budget
///
/// Demonstrates cost-budget enforcement across a fan-out of serial worker
/// steps. A planner agent iterates three workers, each charging $0.20 to the
/// job's USD budget ($0.50 cap). Worker 3 exhausts the budget and is skipped
/// cleanly; the job completes with a partial result.
///
/// Spec: §17.3.1 (cost budget), §18.3 (cost rollups)
///
/// Run:
///   cd Recipes/multi-agent-budget && swift run

import ARCP
import Foundation

// MARK: - Worker helper

/// Charges $0.20 for one worker step and returns a result string.
/// Throws `ARCPError.budgetExhausted` if the budget is insufficient.
func runWorkerStep(id: Int, context: any JobContext) async throws -> String {
    try await context.log(level: .info, message: "worker \(id): starting", attributes: nil)

    let remaining = context.budget.remaining(for: "USD") ?? Double.infinity
    try await context.log(
        level: .info,
        message: "worker \(id): budget remaining = $\(String(format: "%.2f", remaining))",
        attributes: nil
    )

    // Throws ARCPError.budgetExhausted(detail:) when remaining < 0.20
    try await context.charge(name: "cost.llm", amount: 0.20, currency: "USD")

    try await Task.sleep(for: .milliseconds(20))
    try await context.log(level: .info, message: "worker \(id): completed", attributes: nil)
    return "result from worker \(id)"
}

// MARK: - Planner agent

/// Fans out to three workers serially, stopping on first budget exhaustion.
struct PlannerAgent: ToolHandler {
    let name = "multi.planner"

    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        try await context.log(
            level: .info,
            message: "planner: fanning out to 3 workers (budget=$0.50, $0.20/worker)",
            attributes: nil
        )

        var results: [String] = []
        var skipped = 0

        for workerId in 1...3 {
            do {
                let result = try await runWorkerStep(id: workerId, context: context)
                results.append(result)
            } catch ARCPError.budgetExhausted(let detail) {
                skipped += 1
                try await context.log(
                    level: .warning,
                    message: "worker \(workerId): budget exhausted — skipping",
                    attributes: ["detail": .string(detail)]
                )
                break
            }
        }

        try await context.log(
            level: .info,
            message: "planner: done (completed=\(results.count) skipped=\(skipped))",
            attributes: nil
        )

        return .value(.object([
            "completed": .int(results.count),
            "skipped":   .int(skipped),
            "results":   .array(results.map { .string($0) }),
        ]))
    }
}

// MARK: - Main

@main struct MultiAgentBudget {
    static func main() async throws {
        let pair = MemoryTransport.makePair()

        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "multi-agent-budget-runtime", version: "1.0.0"),
            supportedCapabilities: Capabilities(costBudget: true),
            auth: BearerAuthValidator(subjectsByToken: ["demo-token": "planner"])
        )
        await runtime.register(PlannerAgent())
        let server = Task { try await runtime.acceptSession(over: pair.server) }

        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "demo-token"),
            client: IdentityBlock(kind: "multi-agent-budget-client", version: "1.0.0"),
            capabilities: Capabilities(costBudget: true)
        )

        print("── multi-agent cost budget: $0.50 cap, 3 workers at $0.20 each ──")

        // Workers 1 and 2 succeed ($0.20 each = $0.40); worker 3 exhausts the cap.
        let env = Envelope(
            sessionId: client.info.sessionId,
            payload: .toolInvoke(ToolInvokePayload(
                tool:       "multi.planner",
                arguments:  .object(["task": .string("decomposed analysis")]),
                costBudget: CostBudget.from(["USD": 0.50])
            ))
        )
        try await client.send(env)
        print("→ multi.planner submitted (budget=USD 0.50)")

        for await reply in client.unhandled {
            switch reply.payload {
            case .jobAccepted(let p):
                print("← job.accepted  job_id=\(p.jobId.rawValue.prefix(8))")

            case .log(let p):
                print("← log[\(p.level)]  \(p.message)")

            case .metric(let p):
                let unit = p.unit.map { " \($0)" } ?? ""
                print("← metric  \(p.name)=\(p.value)\(unit)")

            case .jobCompleted(let p):
                if let r = p.result, case .object(let obj) = r {
                    print("← job.completed  completed=\(obj["completed"] ?? .null)  skipped=\(obj["skipped"] ?? .null)")
                }
                await client.close()
                _ = try? await server.value
                return

            case .jobFailed(let p):
                print("← job.failed  \(p.error.message)")
                await client.close()
                _ = try? await server.value
                return

            default:
                break
            }
        }
    }
}
