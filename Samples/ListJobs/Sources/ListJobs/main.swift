// ARCP v1.1 §6.6 — `session.list_jobs` / `session.jobs` demo.
//
// Hosts a runtime in-process with a slow agent that sleeps until
// cancelled, then submits three jobs and exercises paginated
// `session.list_jobs` requests.

import ARCP
import Foundation

struct SlowAgent: ToolHandler {
    let name = "slow-task"

    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        for _ in 0..<300 {
            try await Task.sleep(for: .milliseconds(100))
            try await context.checkCancellation()
        }
        return .value(.string("done"))
    }
}

@main
struct ListJobsExample {
    static func main() async throws {
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "list-jobs-demo", version: "1.0.0"),
            supportedCapabilities: Capabilities(durableJobs: true),
            auth: BearerAuthValidator(subjectsByToken: ["demo-token": "demo"])
        )
        await runtime.register(SlowAgent())
        let server = Task { try await runtime.acceptSession(over: pair.server) }
        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "demo-token"),
            client: IdentityBlock(kind: "list-jobs-demo-client", version: "1.0.0"),
            capabilities: Capabilities(durableJobs: true)
        )

        // Submit three slow tasks in parallel.
        var jobIds: [JobId] = []
        for label in ["alpha", "beta", "gamma"] {
            let env = Envelope(
                sessionId: client.info.sessionId,
                payload: .toolInvoke(
                    ToolInvokePayload(
                        tool: "slow-task",
                        arguments: .object(["label": .string(label)])
                    )
                )
            )
            try await client.send(env)
            print("submitted (label=\(label))")
            // Drain job.accepted so we can later cancel.
            for await reply in client.unhandled where reply.correlationId == env.id {
                if case .jobAccepted(let p) = reply.payload {
                    jobIds.append(p.jobId)
                }
                break
            }
        }
        // Give the runtime a beat to flip them to running.
        try await Task.sleep(for: .milliseconds(150))

        // Page 1: filter by status=running, limit 2.
        let page1 = try await listJobs(client: client, limit: 2, cursor: nil)
        printPage(page1, label: "page 1")

        // Page 2 if there's a cursor.
        if let cursor = page1.nextCursor {
            let page2 = try await listJobs(client: client, limit: 2, cursor: cursor)
            printPage(page2, label: "page 2")
        }

        // Clean up — cancel each job.
        for jid in jobIds {
            try await client.send(
                Envelope(
                    sessionId: client.info.sessionId,
                    payload: .cancel(
                        CancelPayload(
                            target: .job,
                            targetId: jid.rawValue,
                            reason: "demo cleanup",
                            deadlineMs: 1_000
                        )
                    )
                )
            )
        }
        try await Task.sleep(for: .milliseconds(200))
        await client.close()
        _ = try? await server.value
    }

    static func listJobs(
        client: ARCPClient,
        limit: Int?,
        cursor: String?
    ) async throws -> SessionJobsPayload {
        let request = Envelope(
            sessionId: client.info.sessionId,
            payload: .sessionListJobs(
                SessionListJobsPayload(
                    filter: SessionListJobsFilter(status: ["running", "accepted"]),
                    limit: limit,
                    cursor: cursor
                )
            )
        )
        try await client.send(request)
        for await reply in client.unhandled where reply.correlationId == request.id {
            if case .sessionJobs(let p) = reply.payload {
                return p
            }
        }
        throw ARCPError.aborted(reason: "no session.jobs response")
    }

    static func printPage(_ page: SessionJobsPayload, label: String) {
        print("\(label): \(page.jobs.count) jobs, next_cursor=\(page.nextCursor ?? "nil")")
        for j in page.jobs {
            print(
                "  job_id=\(j.jobId.rawValue) agent=\(j.agent) "
                    + "status=\(j.status) last_event_seq=\(j.lastEventSeq)"
            )
        }
    }
}
