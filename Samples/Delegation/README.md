# Delegation

Research orchestrator that fans a single request out to three peer
runtimes via `agent.delegate`, demultiplexes their event streams, and
tolerates per-peer failure.

## Before ARCP

Each peer agent is reached over its own bespoke HTTP/SSE endpoint. The
orchestrator stands up three separate websockets, parses three different
event formats, and writes three retry loops. Trace context is "added
later" and never quite makes it across the seam.

## With ARCP

```swift
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
```

One transport, one envelope shape, one trace. Per-peer failure is a
typed `job.failed` envelope, not a 502 with a stack trace.

## ARCP primitives

- `agent.delegate` + `trace_id` propagation — RFC §14, §17.1.
- Job lifecycle (accepted → terminal) — §10.2.
- Stream/event multiplexing across `job_id` — §6.4.

## File tour

- `Sources/Delegation/main.swift` — fan-out / `JobMux` / gather /
  synthesize. `JobMux` is the actor that demuxes one inbound stream
  across many `job_id` consumers.
- `Sources/Delegation/Synth.swift` — synthesis stub +
  `ARCPClient.placeholder`.

## Variations

- Bound the fan-out by capability (e.g. only peers advertising
  `arcpx.research.web.v1`).
- Return artifact refs from peers (`job.completed.result_ref`) instead
  of inline results when payloads cross the inline budget (§16).
- Cancel slowest peer once N succeed via `cancel`.
