import Foundation
import Testing

@testable import ARCP

@Suite("lease_constraints.expires_at (ARCP v1.1 §9.5)")
struct LeaseExpiresAtTests {
    @Test("past expires_at at submit is rejected with INVALID_ARGUMENT")
    func pastExpiryRejected() async throws {
        let fixture = try await IntegrationFixture(handler: NoopTool()).open()
        defer { fixture.close() }

        let result = try await fixture.client.invoke(
            tool: "noop",
            arguments: .null,
            leaseConstraints: LeaseConstraints(expiresAt: Date(timeIntervalSinceNow: -1))
        )
        guard case .failed(let error) = result.outcome else {
            Issue.record("expected failed, got \(result.outcome)")
            return
        }
        #expect(error.code == .invalidArgument)
    }

    @Test("checkLeaseExpiration throws LEASE_EXPIRED after expiry elapses")
    func inFlightExpiry() async throws {
        let fixture = try await IntegrationFixture(handler: ExpiringTool()).open()
        defer { fixture.close() }

        let result = try await fixture.client.invoke(
            tool: "expire",
            arguments: .null,
            leaseConstraints: LeaseConstraints(expiresAt: Date(timeIntervalSinceNow: 0.05))
        )
        guard case .failed(let error) = result.outcome else {
            Issue.record("expected failed, got \(result.outcome)")
            return
        }
        #expect(error.code == .leaseExpired)
        #expect(error.details?["expired_at"] != nil)
    }

    @Test("absent lease_constraints leaves checkLeaseExpiration as a no-op")
    func absentExpiryNoop() async throws {
        let fixture = try await IntegrationFixture(handler: ExpiringTool()).open()
        defer { fixture.close() }

        let result = try await fixture.client.invoke(tool: "expire", arguments: .null)
        guard case .completed = result.outcome else {
            Issue.record("expected completed, got \(result.outcome)")
            return
        }
    }
}

private struct NoopTool: ToolHandler {
    let name = "noop"
    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        .empty
    }
}

private struct ExpiringTool: ToolHandler {
    let name = "expire"
    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        try await Task.sleep(for: .milliseconds(100))
        try context.checkLeaseExpiration()
        return .empty
    }
}
