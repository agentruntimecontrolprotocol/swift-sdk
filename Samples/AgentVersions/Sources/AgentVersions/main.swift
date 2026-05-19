// ARCP v1.1 §7.5 — agent versioning (`name@version`) demo.
//
// Configures a runtime that advertises `echo` at versions 1.0.0 and
// 2.0.0 (with 2.0.0 as default), then:
//   1. Submits a job pinning the existing version (`echo@1.0.0`) and
//      asserts that it completes.
//   2. Submits a job pinning a missing version (`echo@9.9.9`) and
//      asserts that the runtime surfaces `AGENT_VERSION_NOT_AVAILABLE`.

import ARCP
import Foundation

struct EchoAgent: ToolHandler {
    let name = "echo"

    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        return .value(invocation.arguments)
    }
}

@main
struct AgentVersionsExample {
    static func main() async throws {
        let inventory: AgentInventory = .rich([
            AgentInventoryEntry(name: "echo", versions: ["1.0.0", "2.0.0"], default: "2.0.0")
        ])
        let caps = Capabilities(durableJobs: true, agents: inventory)
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "agent-versions-demo", version: "1.0.0"),
            supportedCapabilities: caps,
            auth: BearerAuthValidator(subjectsByToken: ["demo-token": "demo"])
        )
        await runtime.register(EchoAgent())
        let server = Task { try await runtime.acceptSession(over: pair.server) }
        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "demo-token"),
            client: IdentityBlock(kind: "agent-versions-demo-client", version: "1.0.0"),
            capabilities: Capabilities(durableJobs: true)
        )
        print("runtime advertised agents: \(String(describing: client.info.negotiatedCapabilities.agents))")

        // 1. Pin to an existing version → should complete.
        let ok = try await client.invoke(
            tool: "echo@1.0.0",
            arguments: .object(["msg": .string("hello")])
        )
        switch ok.outcome {
        case .completed(let p):
            print("echo@1.0.0 → completed, value=\(String(describing: p.result))")
        default:
            print("unexpected outcome for echo@1.0.0: \(ok.outcome)")
        }

        // 2. Pin to a missing version → should fail.
        let bad = try await client.invoke(
            tool: "echo@9.9.9",
            arguments: .object(["msg": .string("hello")])
        )
        switch bad.outcome {
        case .failed(let env):
            print("echo@9.9.9 → \(env.code.rawValue) (\(env.message))")
            precondition(env.code == .agentVersionNotAvailable)
        default:
            print("unexpected outcome for echo@9.9.9: \(bad.outcome)")
        }

        await client.close()
        _ = try? await server.value
        print("done")
    }
}
