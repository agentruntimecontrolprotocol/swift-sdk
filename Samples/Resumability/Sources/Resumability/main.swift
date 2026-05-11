// Durable research job with real crash and resume.
//
// First call:  CRASH_AFTER_STEP=synthesize swift run Resumability
// Second call: RESUME_JOB_ID=...  RESUME_AFTER_MSG_ID=...  \
//              RESUME_CHECKPOINT_ID=... swift run Resumability

import ARCP
import CryptoKit
import Foundation

let steps = ["plan", "gather", "synthesize", "critique", "finalize"]

func stepKey(jobId: JobId, step: String, salt: String) -> IdempotencyKey {
    var hasher = SHA256()
    for p in [jobId.rawValue, step, salt] {
        hasher.update(data: Data(p.utf8))
        hasher.update(data: Data([0]))
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(16)
    return IdempotencyKey("research:\(jobId.rawValue):\(step):\(digest)")
}

func emitProgress(_ client: ARCPClient, jobId: JobId, step: String) async throws {
    let pct = 100.0 * Double((steps.firstIndex(of: step) ?? 0) + 1) / Double(steps.count)
    try await client.send(
        Envelope(
            sessionId: client.info.sessionId, jobId: jobId,
            payload: .jobProgress(JobProgressPayload(percent: pct, message: step))
        )
    )
}

func emitCheckpoint(_ client: ARCPClient, jobId: JobId, step: String) async throws -> String {
    let chk = "chk_\(step)_\(jobId.rawValue.suffix(6))"
    // No typed `job.checkpoint` payload yet — rides as an extension envelope.
    try await client.send(
        Envelope(
            sessionId: client.info.sessionId, jobId: jobId,
            payload: .unknown(
                typeName: "job.checkpoint",
                payload: .object(["checkpoint_id": .string(chk), "label": .string(step)])
            )
        )
    )
    return chk
}

func executeSteps(
    _ client: ARCPClient, jobId: JobId, request: JSONValue,
    startingAt: String, crashAfter: String?
) async throws -> JSONValue {
    var output = request
    for step in steps {
        if steps.firstIndex(of: step)! < steps.firstIndex(of: startingAt)! { continue }
        let key = stepKey(jobId: jobId, step: step, salt: "\(output)")
        try await emitProgress(client, jobId: jobId, step: step)
        output = try await runStep(
            client, jobId: jobId, step: step,
            inputs: .object(["prior": output, "idempotency_key": .string(key.rawValue)]))
        _ = try await emitCheckpoint(client, jobId: jobId, step: step)
        if crashAfter == step {
            print("[crash after \(step); resume with RESUME_JOB_ID=\(jobId.rawValue)]")
            // The whole point of durable jobs: process death is fine.
            exit(137)
        }
    }
    return output
}

func issueResume(
    _ client: ARCPClient, jobId: JobId, afterMessageId: MessageId, checkpointId: String?
) async throws -> String? {
    try await client.send(
        Envelope(
            sessionId: client.info.sessionId, jobId: jobId,
            payload: .resume(
                ResumePayload(
                    afterMessageId: afterMessageId,
                    checkpointId: checkpointId,
                    includeOpenStreams: true
                )
            )
        )
    )
    var last: String?
    for await env in client.unhandled where env.jobId == jobId {
        switch env.payload {
        case .toolError(let e) where e.error.code == .dataLoss:
            throw ARCPError.dataLoss(detail: "retention expired")
        case .unknown(let typeName, let payload) where typeName == "job.checkpoint":
            if case .object(let obj) = payload, case .string(let label) = obj["label"] ?? .null {
                last = label
            }
        case .jobCompleted, .jobFailed, .jobCancelled: return nil
        case .eventEmit(let e) where e.name == "subscription.backfill_complete":
            return last
        default: continue
        }
    }
    return last
}

@main
struct ResumabilityExample {
    static func main() async throws {
        let client: ARCPClient = await .placeholder
        let env = ProcessInfo.processInfo.environment

        if let rj = env["RESUME_JOB_ID"], let after = env["RESUME_AFTER_MSG_ID"] {
            let jobId = JobId(rj)
            let last = try await issueResume(
                client, jobId: jobId,
                afterMessageId: MessageId(after),
                checkpointId: env["RESUME_CHECKPOINT_ID"]
            )
            guard let last, let nextIdx = steps.firstIndex(of: last).map({ $0 + 1 }), nextIdx < steps.count
            else {
                print("nothing to resume")
                await client.close()
                return
            }
            print("[resuming at \(steps[nextIdx])]")
            let final = try await executeSteps(
                client, jobId: jobId, request: .string("<replayed>"),
                startingAt: steps[nextIdx], crashAfter: nil
            )
            try await client.send(
                Envelope(
                    sessionId: client.info.sessionId, jobId: jobId,
                    payload: .jobCompleted(JobCompletedPayload(result: final))
                )
            )
        } else {
            let jobId = JobId("job_\(UUID().uuidString.prefix(12))")
            let request = "Survey CRDT-based collaborative editing in 2026."
            try await client.send(
                Envelope(
                    sessionId: client.info.sessionId, jobId: jobId,
                    payload: .unknown(
                        typeName: "workflow.start",
                        payload: .object([
                            "workflow": .string("research.v1"),
                            "arguments": .object(["request": .string(request)]),
                        ])
                    )
                )
            )
            let final = try await executeSteps(
                client, jobId: jobId, request: .string(request),
                startingAt: steps[0], crashAfter: env["CRASH_AFTER_STEP"]
            )
            try await client.send(
                Envelope(
                    sessionId: client.info.sessionId, jobId: jobId,
                    payload: .jobCompleted(JobCompletedPayload(result: final))
                )
            )
            print("job_id=\(jobId.rawValue)\n\(final)")
        }
        await client.close()
    }
}
