import Foundation
import Testing

@testable import ARCP

@Suite("Client dispatcher unhandled-fallback (issues #55, #59, #60)")
struct ClientDispatchTests {
    @Test("Unknown-job job.progress falls through to unhandled (#55)")
    func progressUnmatched() async throws {
        let pair = MemoryTransport.makePair()
        let client = try await openClient(pair: pair)
        defer { Task { await client.close() } }

        // Inject a job.progress for a job id this client never invoked.
        let strayJobId = JobId.random()
        try await pair.server.send(
            Envelope(
                sessionId: client.info.sessionId,
                jobId: strayJobId,
                payload: .jobProgress(JobProgressPayload(percent: 50.0))
            )
        )

        let envelope = try await firstUnhandled(
            client: client,
            predicate: { env in
                if case .jobProgress = env.payload { return env.jobId == strayJobId }
                return false
            })
        #expect(envelope.jobId == strayJobId)
    }

    @Test("Unknown-job job.result_chunk falls through to unhandled (#59)")
    func resultChunkUnmatched() async throws {
        let pair = MemoryTransport.makePair()
        let client = try await openClient(pair: pair)
        defer { Task { await client.close() } }

        let strayJobId = JobId.random()
        try await pair.server.send(
            Envelope(
                sessionId: client.info.sessionId,
                jobId: strayJobId,
                payload: .jobResultChunk(
                    JobResultChunkPayload(
                        resultId: "r1",
                        chunkSeq: 0,
                        data: "hi",
                        encoding: .utf8,
                        more: true
                    )
                )
            )
        )

        let envelope = try await firstUnhandled(
            client: client,
            predicate: { env in
                if case .jobResultChunk = env.payload { return env.jobId == strayJobId }
                return false
            })
        #expect(envelope.jobId == strayJobId)
    }

    @Test("Uncorrelated tool.error falls through to unhandled (#60)")
    func toolErrorUnmatched() async throws {
        let pair = MemoryTransport.makePair()
        let client = try await openClient(pair: pair)
        defer { Task { await client.close() } }

        try await pair.server.send(
            Envelope(
                sessionId: client.info.sessionId,
                payload: .toolError(
                    ToolErrorPayload(
                        error: ARCPError.notFound(kind: "tool", id: "ghost").toEnvelope()
                    )
                )
            )
        )

        let envelope = try await firstUnhandled(
            client: client,
            predicate: { env in
                if case .toolError = env.payload { return true }
                return false
            })
        if case .toolError = envelope.payload {
            // matched
        } else {
            Issue.record("expected toolError envelope")
        }
    }

    private func openClient(
        pair: (client: MemoryTransport, server: MemoryTransport)
    ) async throws -> ARCPClient {
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "rt", version: "1"),
            supportedCapabilities: Capabilities(durableJobs: true),
            auth: BearerAuthValidator(subjectsByToken: ["t": "alice"])
        )
        Task { _ = try? await runtime.acceptSession(over: pair.server) }
        return try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "t"),
            client: IdentityBlock(kind: "tester", version: "1"),
            capabilities: Capabilities(durableJobs: true)
        )
    }

    private func firstUnhandled(
        client: ARCPClient,
        predicate: @escaping @Sendable (Envelope) -> Bool
    ) async throws -> Envelope {
        try await withThrowingTaskGroup(of: Envelope.self) { group in
            group.addTask {
                for await env in client.unhandled where predicate(env) {
                    return env
                }
                throw ARCPError.unavailable(reason: "unhandled closed", retryAfter: nil)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw ARCPError.deadlineExceeded(operation: "wait unhandled")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
