import Foundation
import Testing

@testable import ARCP

struct IntegrationFixture: Sendable {
    let handler: any ToolHandler
    let capabilities: Capabilities
    let credentialProvisioner: (any CredentialProvisioner)?

    init(
        handler: any ToolHandler,
        capabilities: Capabilities = Capabilities(durableJobs: true, resultChunk: true, costBudget: true),
        credentialProvisioner: (any CredentialProvisioner)? = nil
    ) {
        self.handler = handler
        self.capabilities = capabilities
        self.credentialProvisioner = credentialProvisioner
    }

    func open(capabilities clientCapabilities: Capabilities? = nil) async throws -> OpenFixture {
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "test-runtime", version: "1"),
            supportedCapabilities: capabilities,
            auth: BearerAuthValidator(subjectsByToken: ["t": "alice"]),
            credentialProvisioner: credentialProvisioner
        )
        await runtime.register(handler)
        let serverTask = Task { try await runtime.acceptSession(over: pair.server) }
        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "t"),
            client: IdentityBlock(kind: "test-client", version: "1"),
            capabilities: clientCapabilities ?? capabilities
        )
        return OpenFixture(client: client, serverTask: serverTask)
    }
}

struct OpenFixture: Sendable {
    let client: ARCPClient
    let serverTask: Task<SessionInfo, any Error>

    func close() {
        Task {
            await client.close()
            _ = try? await serverTask.value
        }
    }

    func next(
        matching predicate: @escaping @Sendable (Envelope) -> Bool
    ) async throws -> Envelope {
        try await withThrowingTaskGroup(of: Envelope.self) { group in
            group.addTask {
                for await envelope in client.unhandled where predicate(envelope) {
                    return envelope
                }
                throw ARCPError.unavailable(reason: "unhandled stream closed", retryAfter: nil)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw ARCPError.deadlineExceeded(operation: "waiting for envelope")
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }
}

func waitUntil(
    timeout: Duration = .seconds(2),
    _ predicate: @escaping @Sendable () async -> Bool
) async throws {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout.timeInterval {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw ARCPError.deadlineExceeded(operation: "waiting for condition")
}
