import ARCP
import Foundation

/// Sample 06 — relay scenario: a tool fans a human-input request to multiple
/// destinations (modeled here as the same handler with different latencies),
/// resolving on the first response. Demonstrates the full
/// human.input.request/response loop end-to-end.
@main
struct Sample06RelayHumanInTheLoop {
    static func main() async throws {
        print("Sample 06 — relay HITL (wire \(ARCPVersion.wire))")
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "sample-runtime", version: ARCPVersion.sdk),
            supportedCapabilities: Capabilities(durableJobs: true, humanInput: true),
            auth: BearerAuthValidator(subjectsByToken: ["demo": "alice"])
        )
        await runtime.register(ApprovalTool())
        let serverTask = Task { try await runtime.acceptSession(over: pair.server) }

        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "demo"),
            client: IdentityBlock(kind: "relay-client", version: ARCPVersion.sdk),
            capabilities: Capabilities(durableJobs: true, humanInput: true)
        )
        await client.setHumanInputHandler(FastResponseHandler())

        let result = try await client.invoke(tool: "approve", arguments: .null)
        if case .completed(let payload) = result.outcome {
            print("decision: \(String(describing: payload.result))")
        }
        await client.close()
        _ = try await serverTask.value
    }
}

private struct ApprovalTool: ToolHandler {
    let name = "approve"
    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        try await context.log(level: .info, message: "fanning out approval request", attributes: nil)
        let response = try await context.requestHumanChoice(
            prompt: "Approve refund for ord_4812?",
            options: [
                .init(id: "approve", label: "Approve"),
                .init(id: "deny", label: "Deny"),
            ],
            expiresIn: .seconds(10)
        )
        return .value(.string(response.choiceId))
    }
}

private struct FastResponseHandler: HumanInputHandler {
    func handle(
        _ request: HumanInputRequestPayload, jobId: JobId?
    ) async throws
        -> HumanInputResponsePayload
    {
        HumanInputResponsePayload(value: .string("yes"), respondedBy: "fast-channel")
    }
    func handle(
        _ request: HumanChoiceRequestPayload, jobId: JobId?
    ) async throws
        -> HumanChoiceResponsePayload
    {
        HumanChoiceResponsePayload(choiceId: "approve", respondedBy: "fast-channel")
    }
}
