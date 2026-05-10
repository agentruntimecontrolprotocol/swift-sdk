import Foundation
import Testing

@testable import ARCP

/// End-to-end relay scenario: an "approval" tool requests human input, the
/// client (acting as the relay) returns the first response, and the tool
/// completes with that decision. Parameterized over `MemoryTransport` and
/// `StdioTransport` to validate transport-agnostic behavior. WebSocket
/// server-side support is partial in v0.1 (see CONFORMANCE.md), so it's not
/// exercised here.
@Suite("End-to-end relay scenario")
struct RelayScenarioTests {

    enum TransportKind: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case memory
        case stdio
        var testDescription: String { rawValue }
    }

    @Test("Approval relay completes over each reference transport", arguments: TransportKind.allCases)
    func approvalOverTransport(kind: TransportKind) async throws {
        let pair = try makePair(kind: kind)
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "relay-runtime", version: "0.1"),
            supportedCapabilities: Capabilities(durableJobs: true, humanInput: true),
            auth: BearerAuthValidator(subjectsByToken: ["t": "alice"])
        )
        await runtime.register(ApprovalTool())
        let serverTask = Task { try await runtime.acceptSession(over: pair.server) }

        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "t"),
            client: IdentityBlock(kind: "relay-client", version: "0.1"),
            capabilities: Capabilities(durableJobs: true, humanInput: true)
        )
        await client.setHumanInputHandler(ApproveHandler())

        let result = try await client.invoke(tool: "approve", arguments: .null)
        guard case .completed(let payload) = result.outcome else {
            Issue.record("expected completed, got \(result.outcome)")
            return
        }
        #expect(payload.result == .string("approve"))
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

private struct ApprovalTool: ToolHandler {
    let name = "approve"
    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        let choice = try await context.requestHumanChoice(
            prompt: "Approve?",
            options: [
                .init(id: "approve", label: "Approve"),
                .init(id: "deny", label: "Deny"),
            ],
            expiresIn: .seconds(5)
        )
        return .value(.string(choice.choiceId))
    }
}

private struct ApproveHandler: HumanInputHandler {
    func handle(
        _ request: HumanInputRequestPayload, jobId: JobId?
    ) async throws
        -> HumanInputResponsePayload
    {
        HumanInputResponsePayload(value: .null, respondedBy: "test")
    }
    func handle(
        _ request: HumanChoiceRequestPayload, jobId: JobId?
    ) async throws
        -> HumanChoiceResponsePayload
    {
        HumanChoiceResponsePayload(choiceId: "approve", respondedBy: "test")
    }
}
