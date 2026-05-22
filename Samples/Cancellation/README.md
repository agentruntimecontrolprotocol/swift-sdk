# Cancellation

Two scenarios that exercise the §10.4–§10.5 control surface that
distinguishes ARCP from "agent over plain HTTP":

- `cancel`: cooperative termination with a deadline.
- `interrupt`: pause the job; runtime acknowledges, no termination (RFC §10.5).

## Before ARCP

Cancellation usually means closing the socket or trying to kill the
process. The agent's tool was already mid-network call, so it either
completes anyway (silent waste of money) or leaves a half-applied side
effect. There's no notion of "stop and ask"; the only knob is "stop".

## With ARCP

```swift
// Stop the job; the runtime drives it to a clean checkpoint inside
// `deadlineMs` before terminating.
let ack = try await cancelJob(client, jobId: jid,
                              reason: "user_aborted", deadlineMs: 5_000)
let terminal = try await awaitTerminal(client, jobId: jid)

// Or: pause the job, ask the human, resume.
try await interruptJob(client, jobId: jid,
                       prompt: "Pause and ask before touching prod.")
```

## ARCP primitives

- `cancel` cooperative contract — RFC §10.4 (`cancel.accepted` /
  `cancel.refused`, `deadline_ms`, escalation to `ABORTED`).
- `interrupt` (distinct from cancel) — §10.5; transitions the job to
  `blocked`; runtime sends an `ack`.
- `capabilities.interrupt: false` fallback to `cancel` (§10.5).

## File tour

- `Sources/Cancellation/main.swift` — two scenarios driven by `argv[1]`
  (`cancel` or `interrupt`).
- `Sources/Cancellation/Setup.swift` — `ARCPClient.placeholder`.

## Variations

- After an `interrupt` ack, send a `resume` envelope to unblock the job.
- Send `cancel` against a `stream_id` instead of a `job_id` to
  terminate just one stream — terminal is a `stream.error` with
  `code: CANCELLED` (§10.4).
- Race many peers, cancel the slowest once N succeed.
