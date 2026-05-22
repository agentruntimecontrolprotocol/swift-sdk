# Conformance

This page summarises which ARCP v1.1 surfaces are implemented in the
Swift SDK. The authoritative detail is in
[`CONFORMANCE.md`](../CONFORMANCE.md) at the repo root.

## Implemented (v0.1.0)

| Surface | RFC section | Notes |
|---------|-------------|-------|
| Envelope format | §6.1 | All fields; ULID IDs |
| Four-step handshake | §8.1 | `bearer`, `signed_jwt`, `none` |
| Capability negotiation | §7 | Intersection of client + runtime caps |
| Durable jobs | §10 | State machine, heartbeats, cancel, interrupt |
| Multi-kind streams | §11 | text, event, log, thought, metric, base64 binary + backpressure |
| Permission challenges | §15.4 | Grant, refresh, revoke, expiry sweep |
| Leases: `expires_at` | §9.5 | Submission validation + in-handler expiry check |
| Leases: `cost.budget` | §9.6 | Budget tracking, metrics, `BUDGET_EXHAUSTED` |
| Leases: `model.use` | §9.7 | Wildcard pattern matching, policy helper |
| Provisioned credentials | §9.8 | Issue / rotate / revoke; pluggable provisioner |
| Subscriptions | §13 | Filter, backfill, `backfill_complete` boundary |
| Inline-base64 artifacts | §16 | Retention sweep |
| Resume by `after_message_id` | §19 | — |
| `job.result_chunk` | §8.4 | Chunked streaming of large results |
| `MemoryTransport` | §22 | In-process; used for all tests |
| `StdioTransport` | §22 | NDJSON framing over stdin/stdout |
| `WebSocketTransport` (client) | §22 | Client-side; server partial (see below) |
| SQLite event log | §20 | Queryable, replay-capable |
| Extension registry | §21 | Namespace registration + unknown-type handling |

## Out of scope for v0.1

| Surface | RFC section | Planned |
|---------|-------------|---------|
| mTLS auth | §8.2 | v0.2 |
| OAuth 2 auth | §8.2 | v0.2 |
| Sidecar binary stream frames | §11.3 | v0.2 |
| Scheduled jobs | §14 | v0.2 |
| Multi-agent delegation/handoff | §14 | v0.2 |
| Trust elevation | §15.6 | v0.2 |
| Checkpoint-based resume | §19 | v0.2 |
| Full WebSocket server | §22 | v0.2 (blocked on WebSocketKit internal initializer) |

## Cross-language tracking

Conformance milestones are tracked in the shared `spec/` tree and
GitHub issue milestones. See
[`agentruntimecontrolprotocol/spec`](https://github.com/agentruntimecontrolprotocol/spec).
