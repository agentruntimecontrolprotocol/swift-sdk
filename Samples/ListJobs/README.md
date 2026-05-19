# ListJobs

ARCP v1.1 §6.6 — `session.list_jobs` / `session.jobs`.

A demo runtime hosts a `slow-task` agent that sleeps until cancelled.
The client submits three concurrent invocations, then exercises
`session.list_jobs` with a status filter and pagination (`limit=2`
followed by a follow-up page via `next_cursor`). Finally it cancels
the three jobs.

## ARCP primitives

- `session.list_jobs` request with optional `filter`, `limit`,
  `cursor` — RFC v1.1 §6.6.
- `session.jobs` response carrying `request_id`, `jobs`, and
  `next_cursor` — RFC v1.1 §6.6.
- Read-only inventory scoped to the session's identity — does not
  subscribe to events.

## File tour

- `Sources/ListJobs/main.swift` — runs both the runtime and the
  client in-process over a paired memory transport. Submits three
  slow tasks, sends two paginated `session.list_jobs`, prints the
  returned entries, then cancels everything.
