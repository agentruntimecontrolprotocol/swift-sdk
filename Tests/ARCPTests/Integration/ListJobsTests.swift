import Foundation
import Testing

@testable import ARCP

@Suite("session.list_jobs / session.jobs (ARCP v1.1 §6.6)")
struct ListJobsTests {
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
            client: IdentityBlock(kind: "list-jobs-test", version: "1"),
            capabilities: Capabilities(durableJobs: true)
        )
        return (client, serverTask)
    }

    @Test("Runtime responds to session.list_jobs with session.jobs")
    func listJobsRoundTrip() async throws {
        let pair = try await makePair(handler: SlowSleepTool())
        defer {
            Task {
                await pair.client.close()
                _ = try? await pair.serverTask.value
            }
        }

        // Submit three slow jobs that stay running.
        for label in ["alpha", "beta", "gamma"] {
            let invoke = Envelope(
                sessionId: pair.client.info.sessionId,
                payload: .toolInvoke(
                    ToolInvokePayload(
                        tool: "slow-task",
                        arguments: .object(["label": .string(label)])
                    )
                )
            )
            try await pair.client.send(invoke)
        }
        // Wait for them to be observed as running.
        try await Task.sleep(for: .milliseconds(150))

        // Send a list request and collect response from the unhandled stream.
        let request = Envelope(
            sessionId: pair.client.info.sessionId,
            payload: .sessionListJobs(
                SessionListJobsPayload(
                    filter: SessionListJobsFilter(status: ["running", "accepted"]),
                    limit: 2,
                    cursor: nil
                )
            )
        )
        try await pair.client.send(request)

        var firstPage: SessionJobsPayload?
        let deadline = Date(timeIntervalSinceNow: 2.0)
        for await reply in pair.client.unhandled {
            if Date() > deadline { break }
            if reply.correlationId == request.id,
                case .sessionJobs(let p) = reply.payload
            {
                firstPage = p
                break
            }
        }
        guard let page = firstPage else {
            Issue.record("did not receive session.jobs response")
            return
        }
        #expect(page.requestId == request.id.rawValue)
        #expect(page.jobs.count == 2, "limit=2 should bound the page")
        #expect(page.nextCursor != nil, "third job should produce a next cursor")

        // Second page using the cursor.
        let request2 = Envelope(
            sessionId: pair.client.info.sessionId,
            payload: .sessionListJobs(
                SessionListJobsPayload(
                    filter: SessionListJobsFilter(status: ["running", "accepted"]),
                    limit: 2,
                    cursor: page.nextCursor
                )
            )
        )
        try await pair.client.send(request2)

        var secondPage: SessionJobsPayload?
        let deadline2 = Date(timeIntervalSinceNow: 2.0)
        for await reply in pair.client.unhandled {
            if Date() > deadline2 { break }
            if reply.correlationId == request2.id,
                case .sessionJobs(let p) = reply.payload
            {
                secondPage = p
                break
            }
        }
        guard let p2 = secondPage else {
            Issue.record("did not receive second session.jobs response")
            return
        }
        #expect(p2.jobs.count == 1, "third job lands on page 2")
        #expect(p2.nextCursor == nil, "no further pages")
        // Each entry advertises the tool name as the agent identifier.
        for entry in page.jobs + p2.jobs {
            #expect(entry.agent == "slow-task")
        }
    }

    @Test("Filter by agent name narrows the inventory")
    func filterByAgent() async throws {
        let pair = try await makePair(handler: SlowSleepTool())
        defer {
            Task {
                await pair.client.close()
                _ = try? await pair.serverTask.value
            }
        }
        let invoke = Envelope(
            sessionId: pair.client.info.sessionId,
            payload: .toolInvoke(
                ToolInvokePayload(tool: "slow-task", arguments: .null)
            )
        )
        try await pair.client.send(invoke)
        try await Task.sleep(for: .milliseconds(100))

        let request = Envelope(
            sessionId: pair.client.info.sessionId,
            payload: .sessionListJobs(
                SessionListJobsPayload(
                    filter: SessionListJobsFilter(agent: "does-not-exist")
                )
            )
        )
        try await pair.client.send(request)
        var page: SessionJobsPayload?
        let deadline = Date(timeIntervalSinceNow: 2.0)
        for await reply in pair.client.unhandled {
            if Date() > deadline { break }
            if reply.correlationId == request.id,
                case .sessionJobs(let p) = reply.payload
            {
                page = p
                break
            }
        }
        #expect(page?.jobs.isEmpty == true)
    }
}

/// Handler that sleeps until cancelled — keeps jobs in `running` long enough
/// for `session.list_jobs` to observe them.
private struct SlowSleepTool: ToolHandler {
    let name = "slow-task"

    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        // Loop a few times while observing cancellation; total ~1s.
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            try await context.checkCancellation()
        }
        return .value(.string("done"))
    }
}
