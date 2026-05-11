// Supervisor + worker pool. Heartbeat loss reroutes via idempotency_key.
//
// Same `IdempotencyKey` on every re-dispatch (RFC §6.4): a worker that
// survived the network blip dedupes; it doesn't re-execute.

import ARCP
import Foundation

let heartbeatIntervalSeconds = 15
let deadlineSeconds = heartbeatIntervalSeconds * 2  // RFC §10.3 default N=2

struct WorkerInfo: Sendable {
    let workerId: String
    let role: String
    var lastHeartbeat: Date
    var inFlightJob: JobId?
}

struct PendingTask: Sendable {
    let taskId: String
    let role: String
    let payload: JSONValue
    let idempotencyKey: IdempotencyKey
}

actor Roster {
    var workers: [String: WorkerInfo] = [:]
    var byRole: [String: [String]] = [:]

    func add(_ w: WorkerInfo) {
        workers[w.workerId] = w
        byRole[w.role, default: []].append(w.workerId)
    }
    func candidates(role: String) -> [WorkerInfo] {
        (byRole[role] ?? []).compactMap { workers[$0] }.filter { $0.inFlightJob == nil }
    }
    func setJob(_ workerId: String, _ jobId: JobId?) { workers[workerId]?.inFlightJob = jobId }
    func touch(_ workerId: String) { workers[workerId]?.lastHeartbeat = Date() }
    func stale(now: Date, deadline: TimeInterval) -> [WorkerInfo] {
        workers.values.filter { now.timeIntervalSince($0.lastHeartbeat) > deadline }
    }
    func remove(_ workerId: String) {
        if let w = workers.removeValue(forKey: workerId) {
            byRole[w.role]?.removeAll { $0 == workerId }
        }
    }
}

// Supervisor side --------------------------------------------------------

func dispatch(
    _ client: ARCPClient, task: PendingTask, roster: Roster,
    jobsToTasks: inout [JobId: PendingTask]
) async throws {
    let candidates = await roster.candidates(role: task.role)
    guard let worker = candidates.min(by: { $0.lastHeartbeat < $1.lastHeartbeat }) else {
        throw ARCPError.unavailable(reason: "no idle workers for \(task.role)", retryAfter: nil)
    }
    let env = Envelope(
        sessionId: client.info.sessionId,
        idempotencyKey: task.idempotencyKey,
        payload: .unknown(
            typeName: "agent.delegate",
            payload: .object([
                "target": .string(worker.workerId),
                "task": .string(task.taskId),
                "context": .object(["task_payload": task.payload]),
            ])
        )
    )
    try await client.send(env)
    for await reply in client.unhandled where reply.correlationId == env.id {
        if case .jobAccepted(let p) = reply.payload {
            await roster.setJob(worker.workerId, p.jobId)
            jobsToTasks[p.jobId] = task
        }
        return
    }
}

func supervise(
    _ client: ARCPClient, roster: Roster, jobsToTasks: inout [JobId: PendingTask]
) async throws {
    var jobsToTasksLocal = jobsToTasks
    let reaper = Task {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(heartbeatIntervalSeconds))
            let stale = await roster.stale(now: Date(), deadline: TimeInterval(deadlineSeconds))
            for w in stale {
                if let jid = w.inFlightJob, let task = jobsToTasksLocal.removeValue(forKey: jid) {
                    try? await dispatch(client, task: task, roster: roster, jobsToTasks: &jobsToTasksLocal)
                }
                await roster.remove(w.workerId)
            }
        }
    }
    defer { reaper.cancel() }

    for await env in client.unhandled {
        switch env.payload {
        case .jobHeartbeat:
            // Find which worker owns env.jobId and refresh.
            for w in await roster.workers.values where w.inFlightJob == env.jobId {
                await roster.touch(w.workerId)
            }
        case .jobCompleted, .jobFailed, .jobCancelled:
            if let jid = env.jobId {
                jobsToTasksLocal.removeValue(forKey: jid)
                for w in await roster.workers.values where w.inFlightJob == jid {
                    await roster.setJob(w.workerId, nil)
                }
            }
        default: break
        }
    }
}

// Worker side ------------------------------------------------------------

func heartbeatLoop(_ client: ARCPClient, jobId: JobId) async throws {
    var seq = 0
    while !Task.isCancelled {
        try await client.send(
            Envelope(
                sessionId: client.info.sessionId, jobId: jobId,
                payload: .jobHeartbeat(
                    JobHeartbeatPayload(
                        sequence: seq,
                        deadlineMs: heartbeatIntervalSeconds * 2_000,
                        state: .running
                    )
                )
            )
        )
        seq += 1
        try? await Task.sleep(for: .seconds(heartbeatIntervalSeconds))
    }
}

func runWorker(_ client: ARCPClient) async throws {
    for await env in client.unhandled {
        if case .unknown(let typeName, _) = env.payload, typeName == "agent.delegate" {
            let jobId = JobId("job_\(UUID().uuidString.prefix(10))")
            try await client.send(
                Envelope(
                    sessionId: client.info.sessionId, jobId: jobId,
                    correlationId: env.id,
                    payload: .jobAccepted(JobAcceptedPayload(jobId: jobId))
                ))
            try await client.send(
                Envelope(
                    sessionId: client.info.sessionId, jobId: jobId,
                    payload: .jobStarted(JobStartedPayload(jobId: jobId))
                ))
            let hb = Task { try await heartbeatLoop(client, jobId: jobId) }
            do {
                let result = try await doWork(payload: env.payload)
                try await client.send(
                    Envelope(
                        sessionId: client.info.sessionId, jobId: jobId,
                        payload: .jobCompleted(JobCompletedPayload(result: result))
                    ))
            } catch {
                try await client.send(
                    Envelope(
                        sessionId: client.info.sessionId, jobId: jobId,
                        payload: .jobFailed(
                            JobFailedPayload(
                                error: ErrorEnvelope(code: .internal, message: "\(error)", retryable: true)
                            ))
                    ))
            }
            hb.cancel()
        }
    }
}

@main
struct HeartbeatsExample {
    static func main() async throws {
        let supervisor: ARCPClient = await .placeholder
        let roster = Roster()
        var jobsToTasks: [JobId: PendingTask] = [:]

        // In production each worker is its own process; co-hosted for the demo.
        for role in ["indexer", "extractor", "archiver"] {
            for _ in 0..<2 {
                let w: ARCPClient = await .placeholder
                Task { try await runWorker(w) }
                await roster.add(
                    WorkerInfo(
                        workerId: "\(role)-\(UUID().uuidString.prefix(6))",
                        role: role, lastHeartbeat: Date(), inFlightJob: nil
                    ))
            }
        }

        Task { try await supervise(supervisor, roster: roster, jobsToTasks: &jobsToTasks) }

        for n in 0..<6 {
            let role = ["indexer", "extractor", "archiver"][n % 3]
            try await dispatch(
                supervisor,
                task: PendingTask(
                    taskId: "t\(String(format: "%03d", n))",
                    role: role,
                    payload: .object(["shard": .number(Double(n))]),
                    idempotencyKey: IdempotencyKey("openclaw:t\(String(format: "%03d", n))")
                ),
                roster: roster,
                jobsToTasks: &jobsToTasks
            )
        }

        try await Task.sleep(for: .seconds(60))
        await supervisor.close()
    }
}
