// Fan a request out to peer runtimes; tolerate partial failure.
//
// `agent.delegate` is not modeled as a typed envelope in the SDK yet —
// we mint it as an `arcpx.agent.delegate.v1` extension envelope that
// rides the same wire shape per RFC §14, §21.

import ARCP
import Foundation

let peers = ["research.web", "research.code", "research.docs"]
let terminalTypes: Set<String> = ["job.completed", "job.failed", "job.cancelled"]

struct DelegatedJob: Sendable {
    let target: String
    var jobId: JobId?
    var final: JSONValue?
    var error: (code: String, message: String)?
}

func delegate(
    _ client: ARCPClient, target: String, task: String, traceId: TraceId
) async throws -> DelegatedJob {
    let env = Envelope(
        sessionId: client.info.sessionId,
        traceId: traceId,
        payload: .unknown(
            typeName: "agent.delegate",
            payload: .object([
                "target": .string(target),
                "task": .string(task),
                "context": .object(["trace_id": .string(traceId.rawValue)]),
            ])
        )
    )
    try await client.send(env)
    for await reply in client.unhandled where reply.correlationId == env.id {
        if case .jobAccepted(let p) = reply.payload {
            return DelegatedJob(target: target, jobId: p.jobId)
        }
        return DelegatedJob(
            target: target, jobId: nil, final: nil,
            error: (code: "FAILED_PRECONDITION", message: "did not accept")
        )
    }
    return DelegatedJob(target: target, jobId: nil, final: nil, error: ("UNAVAILABLE", "no reply"))
}

/// Single reader on `client.unhandled`; fans out by `job_id`.
/// Without this, parallel readers starve each other — only one wins per await.
actor JobMux {
    private var queues: [JobId: AsyncStream<Envelope>.Continuation] = [:]
    private var streams: [JobId: AsyncStream<Envelope>] = [:]

    func register(_ jobId: JobId) -> AsyncStream<Envelope> {
        let (stream, cont) = AsyncStream<Envelope>.makeStream()
        queues[jobId] = cont
        streams[jobId] = stream
        return stream
    }

    func deliver(_ env: Envelope) {
        guard let jid = env.jobId, let cont = queues[jid] else { return }
        cont.yield(env)
        if terminalTypes.contains(env.payload.typeName) {
            cont.finish()
            queues.removeValue(forKey: jid)
        }
    }
}

func collect(_ mux: JobMux, job: DelegatedJob) async -> DelegatedJob {
    var out = job
    guard let jid = job.jobId else { return out }
    let stream = await mux.register(jid)
    for await env in stream {
        switch env.payload {
        case .jobCompleted(let p): out.final = .object(["result": p.result ?? .null])
        case .jobFailed(let p): out.error = (code: p.error.code.rawValue, message: p.error.message)
        case .jobCancelled: out.error = ("CANCELLED", "cancelled")
        default: break
        }
    }
    return out
}

@main
struct DelegationExample {
    static func main() async throws {
        let client: ARCPClient = await .placeholder
        let mux = JobMux()

        let reader = Task {
            for await env in client.unhandled { await mux.deliver(env) }
        }

        let request = "what changed in our auth stack in the last 30 days?"
        let traceId = TraceId("trace_\(UUID().uuidString.prefix(12))")

        var jobs: [DelegatedJob] = []
        for peer in peers {
            jobs.append(try await delegate(client, target: peer, task: request, traceId: traceId))
        }

        let completed = await withTaskGroup(of: DelegatedJob.self) { group in
            for j in jobs { group.addTask { await collect(mux, job: j) } }
            var out: [DelegatedJob] = []
            for await done in group { out.append(done) }
            return out
        }

        print(synthesize(request: request, jobs: completed))
        reader.cancel()
        await client.close()
    }
}
