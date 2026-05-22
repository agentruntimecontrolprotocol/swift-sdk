import Foundation
import Testing

@testable import ARCP

@Suite("provisioned_credentials integration (ARCP v1.1 §9.8)")
struct ProvisionedCredentialsTests {
    @Test("provisioner issues credentials on job.accepted")
    func credentialOnAccepted() async throws {
        let provisioner = InMemoryCredentialProvisioner()
        let fixture = try await IntegrationFixture(
            handler: CredentialNoopTool(),
            capabilities: Capabilities(provisionedCredentials: true),
            credentialProvisioner: provisioner
        ).open(capabilities: Capabilities(provisionedCredentials: true))
        defer { fixture.close() }

        try await fixture.client.send(
            Envelope(
                sessionId: fixture.client.info.sessionId,
                payload: .toolInvoke(
                    ToolInvokePayload(
                        tool: "noop",
                        arguments: .null,
                        costBudget: .from(["USD": 1]),
                        modelUse: ModelUse(patterns: ["tier-fast/*"])
                    )
                )
            )
        )
        let accepted = try await fixture.next { if case .jobAccepted = $0.payload { true } else { false } }
        guard case .jobAccepted(let payload) = accepted.payload else { return }
        let credential = try #require(payload.credentials?.first)
        #expect(credential.scheme == CredentialScheme.bearer)
        #expect(credential.constraints?.costBudget == CostBudget.from(["USD": 1]))
        #expect(credential.constraints?.modelUse == ModelUse(patterns: ["tier-fast/*"]))
    }

    @Test("terminal completion revokes credential")
    func completionRevokesCredential() async throws {
        let provisioner = InMemoryCredentialProvisioner()
        let fixture = try await IntegrationFixture(
            handler: CredentialNoopTool(),
            capabilities: Capabilities(provisionedCredentials: true),
            credentialProvisioner: provisioner
        ).open(capabilities: Capabilities(provisionedCredentials: true))
        defer { fixture.close() }

        let result = try await fixture.client.invoke(
            tool: "noop",
            arguments: JSONValue.null,
            costBudget: CostBudget.from(["USD": 1])
        )
        guard case .completed = result.outcome else {
            Issue.record("expected completed, got \(String(describing: result.outcome))")
            return
        }
        try await waitUntil { await !provisioner.revoked.isEmpty }
        #expect(await provisioner.revoked.count == 1)
    }

    @Test("rotation emits log and revokes prior value")
    func rotation() async throws {
        let provisioner = InMemoryCredentialProvisioner()
        let fixture = try await IntegrationFixture(
            handler: RotatingCredentialTool(),
            capabilities: Capabilities(provisionedCredentials: true),
            credentialProvisioner: provisioner
        ).open(capabilities: Capabilities(provisionedCredentials: true))
        defer { fixture.close() }

        async let invoked = fixture.client.invoke(
            tool: "rotate",
            arguments: .null,
            costBudget: .from(["USD": 1])
        )
        let log = try await fixture.next {
            if case .log(let payload) = $0.payload {
                return payload.attributes?["phase"] == .string("credential_rotated")
            }
            return false
        }
        guard case .log(let payload) = log.payload else { return }
        #expect(payload.attributes?["credential_id"] != nil)
        _ = try await invoked
        try await waitUntil { await provisioner.revoked.contains { $0.contains("_0") } }
    }

    @Test("constructing runtime with provisioned_credentials but no provisioner throws")
    func provisionerRequired() throws {
        #expect(throws: ARCPError.self) {
            _ = try ARCPRuntime(
                identity: IdentityBlock(kind: "runtime", version: "1"),
                supportedCapabilities: Capabilities(provisionedCredentials: true),
                auth: BearerAuthValidator(subjectsByToken: ["t": "alice"])
            )
        }
    }

    @Test("capabilities negotiation intersects provisioned_credentials")
    func capabilityNegotiation() async throws {
        let provisioner = InMemoryCredentialProvisioner()
        let fixture = try await IntegrationFixture(
            handler: CredentialNoopTool(),
            capabilities: Capabilities(provisionedCredentials: true),
            credentialProvisioner: provisioner
        ).open(capabilities: Capabilities(provisionedCredentials: true))
        defer { fixture.close() }
        #expect(fixture.client.info.negotiatedCapabilities.provisionedCredentials)
        #expect(fixture.client.info.negotiatedCapabilities.modelUse == false)
    }

    @Test("subset violation on model.use raises LEASE_SUBSET_VIOLATION")
    func subsetViolation() {
        #expect(throws: ARCPError.self) {
            try ModelUsePolicy.assertSubset(
                parent: ModelUse(patterns: ["tier-fast/*"]),
                child: ModelUse(patterns: ["tier-slow/*"])
            )
        }
    }
}

private struct CredentialNoopTool: ToolHandler {
    let name = "noop"
    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        .empty
    }
}

private struct RotatingCredentialTool: ToolHandler {
    let name = "rotate"
    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        let id = "cred_\(invocation.jobId.rawValue)_0"
        let rotated = try await context.rotateCredential(id: id)
        return .value(.object(["credential": .string(rotated.id)]))
    }
}
