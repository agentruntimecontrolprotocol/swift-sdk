/// Recipe: MCP Skill
///
/// Demonstrates bridging an ARCP `tool.invoke` to an MCP `call_tool` RPC.
/// An `MCPToolAdapter` wraps any MCP tool as an ARCP `ToolHandler`, adding
/// lease-expiry checks, cooperative cancellation, cost tracking, and
/// structured logging — capabilities MCP alone does not provide.
///
/// Replace `MCPStub` with a real MCP SDK client (e.g.
/// modelcontextprotocol/swift-sdk) and wire it to your server for production.
///
/// Spec: §20 (MCP interop), §15.4 (lease), §10 (cancellation), §18.3 (cost)
///
/// Run:
///   cd Recipes/mcp-skill && swift run

import ARCP
import Foundation

// MARK: - MCP stub
// Elides the real MCP transport. Replace with `import MCP` and a real
// `Client` opened over stdio or SSE in production.

struct MCPStub: Sendable {
    struct MCPResult: Sendable {
        let content: String
        let tokenCount: Int
    }

    func call(tool: String, arguments: JSONValue) async throws -> MCPResult {
        // Real implementation: send `call_tool` request over MCP transport.
        try await Task.sleep(for: .milliseconds(50))
        return MCPResult(
            content: "Top results from MCP tool '\(tool)': [1] ARCP spec §1, [2] ARCP SDK docs",
            tokenCount: 42
        )
    }
}

// MARK: - ARCP → MCP adapter

/// Wraps any MCP tool as an ARCP `ToolHandler`.
///
/// What the ARCP layer adds over a raw MCP call:
/// - `checkLeaseExpiration()` — fail fast if the job's lease has expired
/// - `checkCancellation()` — cooperatively honour a `cancel` or `interrupt`
/// - `charge(name:amount:currency:)` — deduct per-token cost from the budget
/// - `metric(name:value:unit:dims:)` — emit token-count metric to the client
/// - `log(level:message:attributes:)` — structured logging in the job stream
struct MCPToolAdapter: ToolHandler {
    let name: String          // ARCP tool name (also forwarded as the MCP tool name)
    let costPerToken: Double  // USD per output token
    let mcp = MCPStub()

    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        // 1. Fail fast if the job's lease has expired.
        try context.checkLeaseExpiration()

        // 2. Check for cooperative cancellation before blocking I/O.
        try await context.checkCancellation()

        try await context.log(
            level: .info,
            message: "forwarding to MCP tool: \(name)",
            attributes: nil
        )

        // 3. Forward to MCP server.
        let result = try await mcp.call(tool: name, arguments: invocation.arguments)

        // 4. Charge per-token cost from the job's cost budget.
        let tokenCost = Double(result.tokenCount) * costPerToken
        try await context.charge(name: "cost.mcp.tokens", amount: tokenCost, currency: "USD")

        // 5. Emit token-count metric for observability.
        try await context.metric(
            name:  "mcp.token_count",
            value: Double(result.tokenCount),
            unit:  "tokens",
            dims:  ["tool": .string(name)]
        )

        try await context.log(
            level: .info,
            message: "MCP returned \(result.tokenCount) tokens: \(result.content)",
            attributes: nil
        )

        return .value(.object([
            "content":     .string(result.content),
            "token_count": .int(result.tokenCount),
            "source":      .string("mcp.\(name)"),
        ]))
    }
}

// MARK: - Main

@main struct MCPSkill {
    static func main() async throws {
        let pair = MemoryTransport.makePair()

        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "mcp-skill-runtime", version: "1.0.0"),
            supportedCapabilities: Capabilities(),
            auth: BearerAuthValidator(subjectsByToken: ["demo-token": "client"])
        )

        // Register one adapter per MCP tool you want to expose over ARCP.
        await runtime.register(MCPToolAdapter(name: "web_search",   costPerToken: 0.00001))
        await runtime.register(MCPToolAdapter(name: "code_execute", costPerToken: 0.00002))

        let server = Task { try await runtime.acceptSession(over: pair.server) }

        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "demo-token"),
            client: IdentityBlock(kind: "mcp-skill-client", version: "1.0.0"),
            capabilities: Capabilities()
        )

        print("── ARCP → MCP bridge: tool.invoke → call_tool → job.completed ──")

        // Invoke via ARCP — the adapter handles lease, cancel, cost, and logging.
        let env = Envelope(
            sessionId: client.info.sessionId,
            payload: .toolInvoke(ToolInvokePayload(
                tool:      "web_search",
                arguments: .object(["query": .string("ARCP protocol specification")])
            ))
        )
        try await client.send(env)
        print("→ web_search submitted")

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
                    print("← job.completed")
                    if case .string(let s) = obj["content"] {
                        print("   content=\(s)")
                    }
                    if case .int(let n) = obj["token_count"] {
                        print("   token_count=\(n)")
                    }
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
