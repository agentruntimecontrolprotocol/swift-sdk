import ARCP
import Foundation

/// Sample 03 — tool requests human input mid-execution, the client's
/// HumanInputHandler resolves it, the tool returns the response value.
@main
struct Sample03HumanInputRequest {
    static func main() async throws {
        print("Sample 03 — human.input.request (wire \(ARCPVersion.wire))")
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "sample-runtime", version: ARCPVersion.sdk),
            supportedCapabilities: Capabilities(durableJobs: true, humanInput: true),
            auth: BearerAuthValidator(subjectsByToken: ["demo": "alice"])
        )
        await runtime.register(BranchAsker())
        let serverTask = Task { try await runtime.acceptSession(over: pair.server) }

        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "demo"),
            client: IdentityBlock(kind: "sample-client", version: ARCPVersion.sdk),
            capabilities: Capabilities(durableJobs: true, humanInput: true)
        )
        await client.setHumanInputHandler(StubBranchHandler())

        let result = try await client.invoke(tool: "askBranch", arguments: .null)
        if case .completed(let payload) = result.outcome {
            print("branch chosen: \(String(describing: payload.result))")
        }
        await client.close()
        _ = try await serverTask.value
    }
}

private struct BranchAsker: ToolHandler {
    let name = "askBranch"
    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        let response = try await context.requestHumanInput(
            prompt: "What branch should I create?",
            responseSchema: nil,
            default: .object(["branch": .string("fix/auto")]),
            expiresIn: .seconds(10)
        )
        return .value(response.value)
    }
}

private struct StubBranchHandler: HumanInputHandler {
    func handle(
        _ request: HumanInputRequestPayload, jobId: JobId?
    ) async throws
        -> HumanInputResponsePayload
    {
        print("→ runtime asks: \(request.prompt)")
        return HumanInputResponsePayload(
            value: .object(["branch": .string("fix/sample")]),
            respondedBy: "sample-handler"
        )
    }
    func handle(
        _ request: HumanChoiceRequestPayload, jobId: JobId?
    ) async throws
        -> HumanChoiceResponsePayload
    {
        HumanChoiceResponsePayload(choiceId: request.options.first?.id ?? "")
    }
}
