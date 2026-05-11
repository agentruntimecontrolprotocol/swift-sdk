# Heartbeats

Dynamic peer-runtime federation. Workers register, take work via
`agent.delegate`, send heartbeats, and deregister cleanly. Heartbeat
loss reroutes the in-flight task to another worker — deduped by
`idempotency_key`.

## Before ARCP

Static worker pools with bespoke RPCs. The supervisor's "is this worker
alive?" answer comes from a TCP keepalive (lies during GC) or a custom
heartbeat that re-dispatch logic doesn't actually trust — so re-dispatch
either fires too eagerly (duplicate execution) or not at all
(stuck pipeline).

## With ARCP

```swift
let stale = await roster.stale(now: Date(), deadline: deadline)
for w in stale {
    if let jid = w.inFlightJob, let task = jobsToTasksLocal.removeValue(forKey: jid) {
        try? await dispatch(client, task: task, roster: roster, jobsToTasks: &jobsToTasksLocal)
    }
    await roster.remove(w.workerId)
}
```

`IdempotencyKey` makes re-dispatch safe: a worker that survived the
network blip will see the duplicate `agent.delegate` and dedupe.

## ARCP primitives

- Capability negotiation (per-role extension) — RFC §7, §21.
- `agent.delegate` — §14.
- Job lifecycle (accepted → started → heartbeat → terminal) — §10.
- Heartbeat loss recovery — §10.3 (`heartbeat_recovery: "block"`).
- `idempotency_key` for safe re-dispatch — §6.4.
- Trust levels — §15.3.

## File tour

- `Sources/Heartbeats/main.swift` — supervisor + small worker pool
  in-process. `Roster` actor holds per-worker freshness; `dispatch`
  reuses the same `IdempotencyKey` on every retry.
- `Sources/Heartbeats/Work.swift` — `doWork` stub +
  `ARCPClient.placeholder`.

## Variations

- Priority queues by tagging tasks with envelope `priority`.
- Per-worker quota tracked via `tokens.used` metrics emitted from
  worker sessions (RFC §17.3.1).
- Replace the in-process workers with separate processes on real
  hosts; the protocol shape doesn't change.
