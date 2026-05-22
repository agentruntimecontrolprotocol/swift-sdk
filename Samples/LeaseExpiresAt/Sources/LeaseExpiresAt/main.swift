import ARCP
import Foundation

struct SlowLeaseTool: ToolHandler {
    let name = "slow-lease"

    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        try await Task.sleep(for: .milliseconds(250))
        try context.checkLeaseExpiration()
        return .empty
    }
}

@main
struct LeaseExpiresAtExample {
    static func main() async throws {
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "lease-expiry-demo", version: "1"),
            supportedCapabilities: Capabilities(),
            auth: BearerAuthValidator(subjectsByToken: ["demo-token": "demo"])
        )
        await runtime.register(SlowLeaseTool())
        let server = Task { try await runtime.acceptSession(over: pair.server) }
        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "demo-token"),
            client: IdentityBlock(kind: "lease-expiry-client", version: "1")
        )

        let result = try await client.invoke(
            tool: "slow-lease",
            arguments: .null,
            leaseConstraints: LeaseConstraints(expiresAt: Date(timeIntervalSinceNow: 0.1))
        )
        if case .failed(let error) = result.outcome {
            print("job.failed code=\(error.code.rawValue)")
        }

        await client.close()
        _ = try? await server.value
    }
}
