import ARCP
import Foundation

struct CredentialAwareTool: ToolHandler {
    let name = "credential-aware"

    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        try context.checkModelUse("tier-fast/sonnet")
        return .value(.string("credential-bound work complete"))
    }
}

@main
struct ProvisionedCredentialsExample {
    static func main() async throws {
        let pair = MemoryTransport.makePair()
        let provisioner = InMemoryCredentialProvisioner()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "credential-demo", version: "1"),
            supportedCapabilities: Capabilities(provisionedCredentials: true),
            auth: BearerAuthValidator(subjectsByToken: ["demo-token": "demo"]),
            credentialProvisioner: provisioner
        )
        await runtime.register(CredentialAwareTool())
        let server = Task { try await runtime.acceptSession(over: pair.server) }
        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "demo-token"),
            client: IdentityBlock(kind: "credential-client", version: "1"),
            capabilities: Capabilities(modelUse: true, provisionedCredentials: true)
        )

        try await client.send(
            Envelope(
                sessionId: client.info.sessionId,
                payload: .toolInvoke(
                    ToolInvokePayload(
                        tool: "credential-aware",
                        arguments: .null,
                        costBudget: .from(["USD": 1]),
                        modelUse: ModelUse(patterns: ["tier-fast/*"]),
                        leaseConstraints: LeaseConstraints(expiresAt: Date(timeIntervalSinceNow: 60))
                    )
                )
            )
        )

        for await env in client.unhandled {
            if case .jobAccepted(let accepted) = env.payload {
                let credential = accepted.credentials?.first
                print("job.accepted credential_id=\(credential?.id ?? "none") value=<redacted>")
            }
            if case .jobCompleted = env.payload {
                break
            }
        }

        await client.close()
        _ = try? await server.value
    }
}
