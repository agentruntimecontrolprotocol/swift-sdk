import ARCP
import Foundation

/// Sample 02 — register a tool that emits progress, invoke it from a client,
/// and stream both progress events and the terminal job.completed.
@main
struct Sample02ToolInvokeProgress {
    static func main() async throws {
        print("Sample 02 — tool.invoke with progress (wire \(ARCPVersion.wire))")
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "sample-runtime", version: ARCPVersion.sdk),
            supportedCapabilities: Capabilities(streaming: true, durableJobs: true),
            auth: BearerAuthValidator(subjectsByToken: ["demo": "alice"])
        )
        await runtime.register(CountingTool())
        let serverTask = Task { try await runtime.acceptSession(over: pair.server) }

        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "demo"),
            client: IdentityBlock(kind: "sample-client", version: ARCPVersion.sdk),
            capabilities: Capabilities(streaming: true, durableJobs: true)
        )

        let result = try await client.invoke(
            tool: "count",
            arguments: .object(["upTo": .int(5)])
        )
        for await progress in result.progress {
            print("progress: \(progress.percent ?? 0)% — \(progress.message ?? "")")
        }
        switch result.outcome {
        case .completed(let payload):
            print("completed: \(String(describing: payload.result))")
        case .failed(let env):
            print("failed: \(env.message)")
        case .cancelled(let payload):
            print("cancelled: \(payload.reason)")
        }

        await client.close()
        _ = try await serverTask.value
    }
}

private struct CountingTool: ToolHandler {
    let name = "count"
    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        guard case .object(let dict) = invocation.arguments,
            case .int(let upTo) = dict["upTo"]
        else {
            throw ARCPError.invalidArgument(field: "upTo", detail: "expected int")
        }
        for i in 1...upTo {
            try await context.reportProgress(
                percent: Double(i) / Double(upTo) * 100.0,
                message: "step \(i)/\(upTo)",
                attributes: nil
            )
            try await Task.sleep(for: .milliseconds(20))
        }
        return .value(.int(upTo))
    }
}
