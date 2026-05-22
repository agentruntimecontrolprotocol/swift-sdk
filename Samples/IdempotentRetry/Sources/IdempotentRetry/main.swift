// ARCP v1.1 §7.2 / §13.5 — idempotency key deduplication.
//
// The same `(principal, idempotency_key)` pair submitted twice yields the
// SAME `job_id` on both replies — the runtime detects the duplicate and
// returns the existing job rather than dispatching a second one.
//
// A different `idempotency_key` from the same principal always creates a
// fresh job.
//
// Practical use-case: a client crashes mid-flight, restarts, re-sends the
// same envelope with the same idempotency key, and picks up the already-
// running job instead of launching a duplicate.
//
// Wire invariant (RFC §7.2):
//   same key + same principal  →  same job_id       (idempotent replay)
//   same key + different agent  →  DUPLICATE_KEY error (cross-session conflict)
//   different key               →  new job_id

import ARCP
import Foundation

// ---------------------------------------------------------------------------
// Agent
// ---------------------------------------------------------------------------

struct SlowTransformAgent: ToolHandler {
    let name = "slow-transform"

    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        // Log the idempotency key so we can confirm deduplication.
        let key = invocation.idempotencyKey?.rawValue ?? "(none)"
        try await context.log(
            level: .info,
            message: "executing idempotency_key=\(key)",
            attributes: nil
        )
        // Simulate real work.
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(30))
            try await context.checkCancellation()
        }
        return .value(.string("transformed"))
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Send `tool.invoke` with an idempotency key and return the accepted job_id.
func submitWithKey(
    client: ARCPClient,
    key: IdempotencyKey
) async throws -> (jobId: JobId, envId: MessageId) {
    let env = Envelope(
        sessionId: client.info.sessionId,
        idempotencyKey: key,
        payload: .toolInvoke(
            ToolInvokePayload(
                tool: "slow-transform",
                arguments: .object(["data": .string("hello")])
            )
        )
    )
    try await client.send(env)
    for await reply in client.unhandled where reply.correlationId == env.id {
        if case .jobAccepted(let p) = reply.payload {
            return (p.jobId, env.id)
        }
        break
    }
    throw ARCPError.aborted(reason: "no job.accepted")
}

/// Drain all events for `jobId` until terminal.
func awaitCompletion(client: ARCPClient, jobId: JobId) async throws {
    for await env in client.unhandled where env.jobId == jobId {
        switch env.payload {
        case .jobCompleted: return
        case .jobFailed(let p): throw ARCPError.aborted(reason: p.error.message)
        default: break
        }
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

@main
struct IdempotentRetryExample {
    static func main() async throws {
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "idempotent-retry-demo", version: "1.0.0"),
            supportedCapabilities: Capabilities(durableJobs: true),
            auth: BearerAuthValidator(subjectsByToken: ["demo-token": "demo"])
        )
        await runtime.register(SlowTransformAgent())
        let server = Task { try await runtime.acceptSession(over: pair.server) }

        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "demo-token"),
            client: IdentityBlock(kind: "idempotent-retry-client", version: "1.0.0"),
            capabilities: Capabilities(durableJobs: true)
        )

        // --- Scenario 1: same key submitted twice → same job_id. ---
        let key = IdempotencyKey(rawValue: "transform-req-001")
        let (jobId1, envId1) = try await submitWithKey(client: client, key: key)
        print("first  submit envId=\(envId1.rawValue.prefix(8)) → job_id=\(jobId1.rawValue.prefix(8))")

        // Simulate a network blip: re-send the exact same key immediately.
        let (jobId2, envId2) = try await submitWithKey(client: client, key: key)
        print("second submit envId=\(envId2.rawValue.prefix(8)) → job_id=\(jobId2.rawValue.prefix(8))")

        if jobId1 == jobId2 {
            print("✓ idempotent: both submissions returned the SAME job_id")
        } else {
            print("✗ unexpected: different job_ids — deduplication did not fire")
        }

        // Wait for the (single) job to finish.
        try await awaitCompletion(client: client, jobId: jobId1)
        print("job.completed")

        // --- Scenario 2: fresh key → new job. ---
        let freshKey = IdempotencyKey(rawValue: "transform-req-002")
        let (jobId3, _) = try await submitWithKey(client: client, key: freshKey)
        print("fresh  submit → job_id=\(jobId3.rawValue.prefix(8))")

        if jobId3 != jobId1 {
            print("✓ new key created a distinct job")
        }

        try await awaitCompletion(client: client, jobId: jobId3)
        print("done")

        await client.close()
        _ = try? await server.value
    }
}
