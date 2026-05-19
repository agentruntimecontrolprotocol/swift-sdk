// ARCP v1.1 §8.2.1 — structured job.progress body.
//
// The runtime hosts a `refactor` agent that emits five incremental
// progress events with current / total / units / message populated.
// The client prints each one as it arrives.

import ARCP
import Foundation

struct RefactorAgent: ToolHandler {
    let name = "refactor"

    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        let files = [
            "src/auth/middleware.ts",
            "src/auth/login.ts",
            "src/auth/session.ts",
            "src/auth/oauth.ts",
            "src/auth/index.ts",
        ]
        for (idx, file) in files.enumerated() {
            try await context.reportProgress(
                current: Double(idx + 1),
                total: Double(files.count),
                units: "files",
                message: "Refactoring \(file)"
            )
            try await Task.sleep(for: .milliseconds(50))
        }
        return .value(.object(["files": .int(Int64(files.count))]))
    }
}

@main
struct ProgressExample {
    static func main() async throws {
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "progress-demo", version: "1.0.0"),
            supportedCapabilities: Capabilities(durableJobs: true),
            auth: BearerAuthValidator(subjectsByToken: ["demo-token": "demo"])
        )
        await runtime.register(RefactorAgent())
        let server = Task { try await runtime.acceptSession(over: pair.server) }
        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "demo-token"),
            client: IdentityBlock(kind: "progress-demo-client", version: "1.0.0"),
            capabilities: Capabilities(durableJobs: true)
        )

        let result = try await client.invoke(tool: "refactor", arguments: .null)

        // Stream progress events as they arrive.
        for await p in result.progress {
            let current = p.current.map { String(Int($0)) } ?? "?"
            let total = p.total.map { String(Int($0)) } ?? "?"
            let units = p.units ?? ""
            let msg = p.message ?? ""
            print("progress: \(current)/\(total) \(units) — \(msg)")
        }

        switch result.outcome {
        case .completed(let p): print("completed: \(String(describing: p.result))")
        case .failed(let env): print("failed: \(env.code.rawValue) \(env.message)")
        case .cancelled(let p): print("cancelled: \(p.reason)")
        }

        await client.close()
        _ = try? await server.value
    }
}
