# ARCP Swift SDK — Conformance

This document tracks conformance of the Swift SDK against
[RFC 0001 v2](RFC-0001-v2.md). It is honest: rows for phases that have not yet
been implemented carry "Phase N — not implemented". The Phase 7 gate requires
this document to be accurate before tagging `v0.1.0`.

| RFC § | Surface | Status | Notes |
|---|---|---|---|
| §6.1 | Envelope (struct + custom `Codable`) | Phase 1 — not implemented | |
| §6.4 | Idempotency keys (`id`, `idempotency_key`) | Phase 1 — not implemented | |
| §6.5 | Priority/QoS | Phase 1 — not implemented | Default `normal` |
| §7   | Capability negotiation | Phase 2 — not implemented | |
| §8.1 | Four-step handshake | Phase 2 — not implemented | |
| §8.2 | `bearer` auth | Phase 2 — not implemented | |
| §8.2 | `signed_jwt` auth | Phase 2 — not implemented | Validated via `jwt-kit` |
| §8.2 | `none` auth (anonymous) | Phase 2 — not implemented | Requires `anonymous` capability |
| §8.2 | `mtls` auth | **Out of scope v0.1** | Throws `.unimplemented(§8.2)` |
| §8.2 | `oauth2` auth | **Out of scope v0.1** | Throws `.unimplemented(§8.2)` |
| §8.4 | Re-authentication | Phase 2 — not implemented | |
| §8.5 | Eviction | Phase 2 — not implemented | |
| §9   | Stateless and stateful sessions | Phase 2 — not implemented | |
| §9   | Durable sessions | **Out of scope v0.1** | |
| §10.1 | Durable jobs | Phase 3 — not implemented | |
| §10.2 | Job state machine | Phase 3 — not implemented | Modeled as enum w/ associated values |
| §10.3 | Heartbeats (default `N=2`) | Phase 3 — not implemented | Deterministic via injected `Clock` |
| §10.4 | Cancellation (cooperative + escalation) | Phase 3 — not implemented | |
| §10.5 | Interrupts | Phase 3 — not implemented | |
| §10.6 | Scheduled jobs (`job.schedule`) | **Out of scope v0.1** | |
| §11.1 | Stream kinds (`text`, `event`, `log`, `thought`) | Phase 3 — not implemented | |
| §11.1 | Stream kind `binary` (base64) | Phase 3 — not implemented | |
| §11.2 | Backpressure | Phase 3 — not implemented | 80%/50% thresholds |
| §11.3 | Sidecar binary frames | **Out of scope v0.1** | base64 only |
| §11.4 | Reasoning streams (`kind: thought`) | Phase 3 — not implemented | |
| §12.1 | `human.input.request/response` | Phase 4 — not implemented | |
| §12.2 | `human.choice.request/response` | Phase 4 — not implemented | |
| §12.3 | Multi-channel resolution (first-wins) | Phase 4 — not implemented | Quorum is out of scope |
| §12.4 | Expiration with default fallback | Phase 4 — not implemented | |
| §13.1 | Subscriptions | Phase 5 — not implemented | |
| §13.2 | Filter authorization at compile time | Phase 5 — not implemented | |
| §13.3 | Backfill + `subscription.backfill_complete` | Phase 5 — not implemented | |
| §13.4 | `unsubscribe`, `subscribe.closed` | Phase 5 — not implemented | |
| §14   | Multi-agent (`agent.delegate`, `agent.handoff`) | **Out of scope v0.1** | |
| §15.1 | Permission model | Phase 4 — not implemented | |
| §15.2 | Sandboxing | Out of scope (deployment concern) | |
| §15.3 | Trust levels | Phase 4 — not implemented | |
| §15.4 | Permission challenge flow | Phase 4 — not implemented | |
| §15.5 | Lease lifecycle | Phase 4 — not implemented | |
| §15.6 | Trust elevation | **Out of scope v0.1** | |
| §16.1 | `artifact.ref` | Phase 5 — not implemented | |
| §16.2 | `artifact.put/fetch/release` (inline base64) | Phase 5 — not implemented | |
| §16.3 | Retention sweep | Phase 5 — not implemented | |
| §17.1 | Trace propagation (`@TaskLocal`) | Phase 1 — not implemented | |
| §17.2 | Structured logs via swift-log | Phase 1 — not implemented | |
| §17.3 | Metrics | Phase 1 — not implemented | |
| §17.3.1 | Reserved metric names as `static let` | Phase 1 — not implemented | |
| §18.1 | Error envelope | Phase 1 — not implemented | |
| §18.2 | Canonical error taxonomy | Phase 1 — not implemented | Enum w/ associated values |
| §18.3 | Retryability flag (`isRetryable`) | Phase 1 — not implemented | |
| §19   | Resume by `after_message_id` | Phase 5 — not implemented | |
| §19   | Checkpoint-based resume | **Out of scope v0.1** | |
| §20   | MCP compatibility | Future (parallel concept layer) | |
| §21   | Extension registry | Phase 1 — not implemented | |
| §21.3 | Unknown-message handling | Phase 1 — not implemented | |
| §22   | WebSocket transport | Phase 6 — not implemented | `vapor/websocket-kit` |
| §22   | stdio transport | Phase 6 — not implemented | NDJSON over stdin/stdout |
| §22   | HTTP/2 transport | **Out of scope v0.1** | |
| §22   | QUIC transport | **Out of scope v0.1** | |

This file is updated at the close of each phase to flip rows to **Implemented**
with a link to the relevant integration test. Phase 7's gate check is that no
in-scope row is still "not implemented".
