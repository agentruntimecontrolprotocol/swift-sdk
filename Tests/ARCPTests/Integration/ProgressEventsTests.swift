import Foundation
import Testing

@testable import ARCP

@Suite("job.progress (ARCP v1.1 §8.2.1)")
struct ProgressEventsTests {
    private func makePair(
        handler: any ToolHandler
    ) async throws -> (client: ARCPClient, serverTask: Task<SessionInfo, any Error>) {
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "example-runtime", version: "0.1"),
            supportedCapabilities: Capabilities(durableJobs: true),
            auth: BearerAuthValidator(subjectsByToken: ["t": "alice"])
        )
        await runtime.register(handler)
        let serverTask = Task { try await runtime.acceptSession(over: pair.server) }
        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "t"),
            client: IdentityBlock(kind: "progress-test", version: "1"),
            capabilities: Capabilities(durableJobs: true)
        )
        return (client, serverTask)
    }

    @Test("Incremental progress carries §8.2.1 current/total/units/message")
    func incrementalProgress() async throws {
        let pair = try await makePair(handler: ProgressTool())
        defer {
            Task {
                await pair.client.close()
                _ = try? await pair.serverTask.value
            }
        }
        let result = try await pair.client.invoke(tool: "progress", arguments: .null)
        guard case .completed = result.outcome else {
            Issue.record("expected completed, got \(result.outcome)")
            return
        }
        var observed: [JobProgressPayload] = []
        for await p in result.progress {
            observed.append(p)
        }
        // The tool emits 3 progress events at 1/3, 2/3, 3/3.
        #expect(observed.count == 3, "expected 3 progress events, got \(observed.count)")
        for (idx, p) in observed.enumerated() {
            #expect(p.current == Double(idx + 1))
            #expect(p.total == 3)
            #expect(p.units == "files")
        }
        #expect(observed.last?.message == "done")
    }

    @Test("Progress payload Codable round-trips §8.2.1 fields")
    func progressPayloadRoundTrip() throws {
        let payload = JobProgressPayload(
            current: 47,
            total: 120,
            units: "files",
            message: "Refactoring src/auth/middleware.ts"
        )
        let data = try JSONEncoder().encode(payload)
        let back = try JSONDecoder().decode(JobProgressPayload.self, from: data)
        #expect(back.current == 47)
        #expect(back.total == 120)
        #expect(back.units == "files")
        #expect(back.message == "Refactoring src/auth/middleware.ts")
        // Wire keys match the spec.
        let raw = String(data: data, encoding: .utf8) ?? ""
        #expect(raw.contains("\"current\":47"))
        #expect(raw.contains("\"total\":120"))
        #expect(raw.contains("\"units\":\"files\""))
    }
}

/// Handler that emits three §8.2.1 progress events with current/total/units.
private struct ProgressTool: ToolHandler {
    let name = "progress"

    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        let total: Double = 3
        for step in 1...3 {
            try await context.reportProgress(
                current: Double(step),
                total: total,
                units: "files",
                message: step == 3 ? "done" : "processing"
            )
            try await Task.sleep(for: .milliseconds(5))
        }
        return .value(.string("ok"))
    }
}
