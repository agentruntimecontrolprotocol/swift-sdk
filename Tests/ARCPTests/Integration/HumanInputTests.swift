import Foundation
import Testing

@testable import ARCP

@Suite("Human input (RFC §12)")
struct HumanInputTests {
    private func makePair(
        handler: any ToolHandler,
        humanHandler: any HumanInputHandler
    ) async throws -> (client: ARCPClient, serverTask: Task<SessionInfo, any Error>) {
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "openclaw", version: "0.1"),
            supportedCapabilities: Capabilities(durableJobs: true, humanInput: true),
            auth: BearerAuthValidator(subjectsByToken: ["t": "alice"])
        )
        await runtime.register(handler)
        let serverTask = Task { try await runtime.acceptSession(over: pair.server) }
        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "t"),
            client: IdentityBlock(kind: "tester", version: "1"),
            capabilities: Capabilities(durableJobs: true, humanInput: true)
        )
        await client.setHumanInputHandler(humanHandler)
        return (client, serverTask)
    }

    @Test("Human input request round-trips through the configured handler")
    func roundTrip() async throws {
        let pair = try await makePair(
            handler: AskToolWithDefault(),
            humanHandler: ScriptedHumanHandler(
                inputResponse: .object(["branch": .string("fix/awesome")])
            )
        )
        defer {
            Task {
                await pair.client.close()
                _ = try? await pair.serverTask.value
            }
        }
        let result = try await pair.client.invoke(tool: "ask", arguments: .null)
        guard case .completed(let payload) = result.outcome else {
            Issue.record("expected completed, got \(result.outcome)")
            return
        }
        #expect(payload.result == .object(["branch": .string("fix/awesome")]))
    }

    @Test("Choice request round-trips and returns the selected id")
    func choiceRoundTrip() async throws {
        let pair = try await makePair(
            handler: ChoiceTool(),
            humanHandler: ScriptedHumanHandler(choiceId: "fix")
        )
        defer {
            Task {
                await pair.client.close()
                _ = try? await pair.serverTask.value
            }
        }
        let result = try await pair.client.invoke(tool: "choice", arguments: .null)
        guard case .completed(let payload) = result.outcome else {
            Issue.record("expected completed, got \(result.outcome)")
            return
        }
        #expect(payload.result == .string("fix"))
    }

    @Test("Expiration with default fallback synthesizes a response")
    func expirationDefaults() async throws {
        let pair = try await makePair(
            handler: AskToolWithDefault(),
            humanHandler: SilentHumanHandler()  // never replies
        )
        defer {
            Task {
                await pair.client.close()
                _ = try? await pair.serverTask.value
            }
        }
        let result = try await pair.client.invoke(tool: "ask", arguments: .null)
        guard case .completed(let payload) = result.outcome else {
            Issue.record("expected completed via default fallback, got \(result.outcome)")
            return
        }
        #expect(payload.result == .object(["branch": .string("fix/auto")]))
    }
}

/// Tool that asks for a branch name, returning the response value.
private struct AskToolWithDefault: ToolHandler {
    let name = "ask"
    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        let response = try await context.requestHumanInput(
            prompt: "branch?",
            responseSchema: nil,
            default: .object(["branch": .string("fix/auto")]),
            expiresIn: .milliseconds(150)
        )
        return .value(response.value)
    }
}

private struct ChoiceTool: ToolHandler {
    let name = "choice"
    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        let response = try await context.requestHumanChoice(
            prompt: "what do?",
            options: [
                .init(id: "fix", label: "Fix and re-run"),
                .init(id: "skip", label: "Skip"),
            ],
            expiresIn: .seconds(2)
        )
        return .value(.string(response.choiceId))
    }
}

private struct ScriptedHumanHandler: HumanInputHandler {
    let inputResponse: JSONValue?
    let choiceId: String?

    init(inputResponse: JSONValue? = nil, choiceId: String? = nil) {
        self.inputResponse = inputResponse
        self.choiceId = choiceId
    }

    func handle(
        _ request: HumanInputRequestPayload, jobId: JobId?
    ) async throws
        -> HumanInputResponsePayload
    {
        guard let inputResponse else {
            throw ARCPError.invalidArgument(field: "value", detail: "no scripted response")
        }
        return HumanInputResponsePayload(value: inputResponse, respondedBy: "test")
    }

    func handle(
        _ request: HumanChoiceRequestPayload, jobId: JobId?
    ) async throws
        -> HumanChoiceResponsePayload
    {
        guard let choiceId else {
            throw ARCPError.invalidArgument(field: "choice_id", detail: "no scripted choice")
        }
        return HumanChoiceResponsePayload(choiceId: choiceId, respondedBy: "test")
    }
}

private struct SilentHumanHandler: HumanInputHandler {
    func handle(
        _ request: HumanInputRequestPayload, jobId: JobId?
    ) async throws
        -> HumanInputResponsePayload
    {
        try await Task.sleep(for: .seconds(60))  // never resolves
        throw ARCPError.cancelled(operation: "silent", reason: "never")
    }

    func handle(
        _ request: HumanChoiceRequestPayload, jobId: JobId?
    ) async throws
        -> HumanChoiceResponsePayload
    {
        try await Task.sleep(for: .seconds(60))
        throw ARCPError.cancelled(operation: "silent", reason: "never")
    }
}
