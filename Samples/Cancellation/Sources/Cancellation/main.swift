// Two scenarios over the §10.4 / §10.5 control surface.
//
// `cancel`    — cooperative termination with a deadline.
// `interrupt` — pause and route through a human, no termination.

import ARCP
import Foundation

let cancelDeadlineMs = 5_000

func startLongJob(_ client: ARCPClient) async throws -> JobId {
    let env = Envelope(
        sessionId: client.info.sessionId,
        payload: .toolInvoke(
            ToolInvokePayload(
                tool: "demo.long_running",
                arguments: .object(["work_seconds": .number(600)])
            )
        )
    )
    try await client.send(env)
    for await reply in client.unhandled where reply.correlationId == env.id {
        if case .jobAccepted(let p) = reply.payload { return p.jobId }
        break
    }
    throw ARCPError.aborted(reason: "no job.accepted")
}

/// Cooperative cancel. Runtime drives target to a clean checkpoint inside
/// `deadlineMs` before terminating; escalates to ABORTED on timeout
/// (RFC §10.4).
func cancelJob(
    _ client: ARCPClient, jobId: JobId, reason: String, deadlineMs: Int
) async throws -> Envelope {
    let env = Envelope(
        sessionId: client.info.sessionId,
        payload: .cancel(
            CancelPayload(
                target: .job, targetId: jobId.rawValue,
                reason: reason, deadlineMs: deadlineMs)
        )
    )
    try await client.send(env)
    for await reply in client.unhandled where reply.correlationId == env.id {
        if case .cancelRefused(let r) = reply.payload {
            throw ARCPError.failedPrecondition(detail: r.reason ?? "cancel refused")
        }
        return reply
    }
    throw ARCPError.aborted(reason: "no cancel reply")
}

/// Distinct from cancel: pauses the job (`blocked`), runtime emits
/// `human.input.request`. Job is NOT terminated (RFC §10.5).
func interruptJob(_ client: ARCPClient, jobId: JobId, prompt: String) async throws {
    try await client.send(
        Envelope(
            sessionId: client.info.sessionId,
            payload: .interrupt(
                InterruptPayload(target: .job, targetId: jobId.rawValue, prompt: prompt)
            )
        )
    )
}

func awaitTerminal(_ client: ARCPClient, jobId: JobId) async throws -> Envelope {
    for await env in client.unhandled where env.jobId == jobId {
        switch env.payload {
        case .jobCompleted, .jobFailed, .jobCancelled: return env
        default: continue
        }
    }
    throw ARCPError.aborted(reason: "stream closed before terminal")
}

func scenarioCancel() async throws {
    let client: ARCPClient = await .placeholder
    defer { Task { await client.close() } }
    let jobId = try await startLongJob(client)
    try await Task.sleep(for: .seconds(2))
    let ack = try await cancelJob(
        client, jobId: jobId,
        reason: "user_aborted", deadlineMs: cancelDeadlineMs)
    print("cancel ack: \(ack.payload.typeName)")
    let terminal = try await awaitTerminal(client, jobId: jobId)
    print("terminal: \(terminal.payload.typeName)")
}

func scenarioInterrupt() async throws {
    let client: ARCPClient = await .placeholder
    defer { Task { await client.close() } }
    let jobId = try await startLongJob(client)
    try await Task.sleep(for: .seconds(2))
    try await interruptJob(
        client, jobId: jobId,
        prompt: "Pause and ask before touching production tables.")
    // Runtime now emits human.input.request; answer via Human-Input.
    for await env in client.unhandled {
        if case .humanInputRequest(let p) = env.payload, env.jobId == jobId {
            print("awaiting human: \(p.prompt)")
            return
        }
    }
}

@main
struct CancellationExample {
    static func main() async throws {
        let which = CommandLine.arguments.dropFirst().first ?? "cancel"
        switch which {
        case "cancel": try await scenarioCancel()
        case "interrupt": try await scenarioInterrupt()
        default: fatalError("unknown scenario: \(which)")
        }
    }
}
