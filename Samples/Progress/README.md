# Progress

ARCP v1.1 §8.2.1 — structured `job.progress` body.

A demo runtime hosts a `refactor` agent that emits incremental
progress events with `current`, `total`, `units`, and `message`
populated. The client prints each event as it arrives.

## ARCP primitives

- `job.progress` payload extended with v1.1 §8.2.1 fields:
  `current` (REQUIRED non-negative), `total` (OPTIONAL — absent
  means indeterminate), `units` (OPTIONAL label), `message`
  (OPTIONAL human-readable status).
- `JobContext.reportProgress(current:total:units:message:)`
  convenience entrypoint on the runtime side.

## File tour

- `Sources/Progress/main.swift` — paired runtime + client over a
  memory transport. The agent emits 5 incremental progress events,
  and the client prints the structured fields as they arrive
  through `InvocationResult.progress`.
