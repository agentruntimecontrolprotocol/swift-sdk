import Foundation
import Testing

@testable import ARCP

@Suite("Agent versioning (ARCP v1.1 §7.5)")
struct AgentVersionsTests {
    private func makePair(
        handler: any ToolHandler,
        inventory: AgentInventory?
    ) async throws -> (client: ARCPClient, serverTask: Task<SessionInfo, any Error>) {
        let pair = MemoryTransport.makePair()
        let caps = Capabilities(durableJobs: true, agents: inventory)
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "example-runtime", version: "0.1"),
            supportedCapabilities: caps,
            auth: BearerAuthValidator(subjectsByToken: ["t": "alice"])
        )
        await runtime.register(handler)
        let serverTask = Task { try await runtime.acceptSession(over: pair.server) }
        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "t"),
            client: IdentityBlock(kind: "agent-versions-test", version: "1"),
            capabilities: Capabilities(durableJobs: true)
        )
        return (client, serverTask)
    }

    @Test("Pinned existing version (echo@1.0.0) runs to completion")
    func existingVersionRuns() async throws {
        let pair = try await makePair(
            handler: EchoTool(),
            inventory: .rich([
                AgentInventoryEntry(
                    name: "echo",
                    versions: ["1.0.0", "2.0.0"],
                    default: "2.0.0"
                )
            ])
        )
        defer {
            Task {
                await pair.client.close()
                _ = try? await pair.serverTask.value
            }
        }
        let result = try await pair.client.invoke(
            tool: "echo@1.0.0",
            arguments: .object(["msg": .string("hi")])
        )
        guard case .completed(let p) = result.outcome else {
            Issue.record("expected completed, got \(result.outcome)")
            return
        }
        #expect(p.result == .object(["msg": .string("hi")]))
    }

    @Test("Bare name still works when inventory advertises versions")
    func bareNameRuns() async throws {
        let pair = try await makePair(
            handler: EchoTool(),
            inventory: .rich([
                AgentInventoryEntry(name: "echo", versions: ["1.0.0"], default: "1.0.0")
            ])
        )
        defer {
            Task {
                await pair.client.close()
                _ = try? await pair.serverTask.value
            }
        }
        let result = try await pair.client.invoke(
            tool: "echo",
            arguments: .object(["msg": .string("hi")])
        )
        guard case .completed = result.outcome else {
            Issue.record("expected completed, got \(result.outcome)")
            return
        }
    }

    @Test("Unknown version surfaces AGENT_VERSION_NOT_AVAILABLE")
    func unknownVersionFails() async throws {
        let pair = try await makePair(
            handler: EchoTool(),
            inventory: .rich([
                AgentInventoryEntry(name: "echo", versions: ["1.0.0"], default: "1.0.0")
            ])
        )
        defer {
            Task {
                await pair.client.close()
                _ = try? await pair.serverTask.value
            }
        }
        let result = try await pair.client.invoke(
            tool: "echo@9.9.9",
            arguments: .object(["msg": .string("hi")])
        )
        guard case .failed(let env) = result.outcome else {
            Issue.record("expected failed outcome, got \(result.outcome)")
            return
        }
        #expect(env.code == .agentVersionNotAvailable)
    }
}

/// Echoes its arguments back unchanged.
private struct EchoTool: ToolHandler {
    let name = "echo"

    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        return .value(invocation.arguments)
    }
}
