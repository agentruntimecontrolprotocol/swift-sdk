import Foundation
import Testing

@testable import ARCP

/// End-to-end relay scenario: a tool emits progress events and completes with a
/// decision string.  Parameterized over `MemoryTransport` and `StdioTransport`
/// to validate transport-agnostic behaviour. WebSocket server-side support is
/// partial in v0.1 (see CONFORMANCE.md), so it is not exercised here.
@Suite("End-to-end relay scenario")
struct RelayScenarioTests {

    enum TransportKind: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case memory
        case stdio
        var testDescription: String { rawValue }
    }

    @Test("Decision relay completes over each reference transport", arguments: TransportKind.allCases)
    func decisionOverTransport(kind: TransportKind) async throws {
        let pair = try makePair(kind: kind)
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "relay-runtime", version: "0.1"),
            supportedCapabilities: Capabilities(durableJobs: true),
            auth: BearerAuthValidator(subjectsByToken: ["t": "alice"])
        )
        await runtime.register(DecisionTool())
        let serverTask = Task { try await runtime.acceptSession(over: pair.server) }

        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "t"),
            client: IdentityBlock(kind: "relay-client", version: "0.1"),
            capabilities: Capabilities(durableJobs: true)
        )

        let result = try await client.invoke(tool: "decide", arguments: .null)
        guard case .completed(let payload) = result.outcome else {
            Issue.record("expected completed, got \(result.outcome)")
            return
        }
        #expect(payload.result == .string("approved"))
        await client.close()
        _ = try await serverTask.value
    }

    private func makePair(kind: TransportKind) throws -> (client: any Transport, server: any Transport) {
        switch kind {
        case .memory:
            let pair = MemoryTransport.makePair()
            return (pair.client, pair.server)
        case .stdio:
            let cToS = Pipe()
            let sToC = Pipe()
            let client = StdioTransport(
                inbound: sToC.fileHandleForReading,
                outbound: cToS.fileHandleForWriting
            )
            let server = StdioTransport(
                inbound: cToS.fileHandleForReading,
                outbound: sToC.fileHandleForWriting
            )
            return (client, server)
        }
    }
}

private struct DecisionTool: ToolHandler {
    let name = "decide"
    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        try await context.reportProgress(percent: 50, message: "evaluating", attributes: nil)
        return .value(.string("approved"))
    }
}
