# ARCP Swift SDK — Conformance

This document tracks conformance of the Swift SDK against
[RFC 0001 v2](RFC-0001-v2.md). It is honest: rows for phases that have not yet
been implemented carry "Phase N — not implemented". The Phase 7 gate requires
this document to be accurate before tagging `v0.1.0`.

| RFC § | Surface | Status | Notes |
|---|---|---|---|
| §6.1 | Envelope (struct + custom `Codable`) | Implemented (Phase 1) | `EnvelopeTests` round-trips every variant |
| §6.4 | Idempotency keys (`id`, `idempotency_key`) | Implemented (Phase 1) | `EventLogTests` |
| §6.5 | Priority/QoS | Implemented (Phase 1) | Default `normal` enforced on decode |
| §7   | Capability negotiation | Implemented (Phase 2) | `CapabilityNegotiator` + `HandshakeTests.capabilityIntersection` |
| §8.1 | Four-step handshake | Implemented (Phase 2) | `ARCPRuntime.runHandshake` + `HandshakeTests` |
| §8.2 | `bearer` auth | Implemented (Phase 2) | `BearerAuthValidator` |
| §8.2 | `signed_jwt` auth | Implemented (Phase 2) | `JWTAuthValidator` (jwt-kit) |
| §8.2 | `none` auth (anonymous) | Implemented (Phase 2) | gated on `anonymous` capability |
| §8.2 | `mtls` auth | **Out of scope v0.1** | Throws `.unimplemented(§8.2)` |
| §8.2 | `oauth2` auth | **Out of scope v0.1** | Throws `.unimplemented(§8.2)` |
| §8.4 | Re-authentication | Phase 2 — not implemented | |
| §8.5 | Eviction | Phase 2 — not implemented | |
| §9   | Stateless and stateful sessions | Implemented (Phase 2) | `SessionInfo` carries negotiated state |
| §9   | Durable sessions | **Out of scope v0.1** | |
| §10.1 | Durable jobs | Implemented (Phase 3) | `JobManager` |
| §10.2 | Job state machine | Implemented (Phase 3) | `JobState` enum + `JobLifecycleTests` |
| §10.3 | Heartbeats (default `N=2`) | Implemented (Phase 3) | `JobManager.heartbeatLoop`; deadline watchdog deferred to Phase 6 |
| §10.4 | Cancellation (cooperative + escalation) | Implemented (Phase 3) | `JobManager.handleCancel` + escalation Task |
| §10.5 | Interrupts | Implemented (Phase 3) | `JobManager.handleInterrupt` (HITL response loop in Phase 4) |
| §10.6 | Scheduled jobs (`job.schedule`) | **Out of scope v0.1** | |
| §11.1 | Stream kinds (`text`, `event`, `log`, `thought`) | Implemented (Phase 3) | `StreamManager` |
| §11.1 | Stream kind `binary` (base64) | Implemented (Phase 3) | `StreamChunkPayload.data` is base64 |
| §11.2 | Backpressure | Implemented (Phase 3) | explicit `BackpressurePayload` envelope |
| §11.3 | Sidecar binary frames | **Out of scope v0.1** | base64 only |
| §11.4 | Reasoning streams (`kind: thought`) | Implemented (Phase 3) | `StreamKind.thought` |
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
| §17.1 | Trace propagation (`@TaskLocal`) | Implemented (Phase 1) | `Tracing.withTrace` |
| §17.2 | Structured logs via swift-log | Implemented (Phase 1) | `LogPayload` + `swift-log` Logger |
| §17.3 | Metrics | Implemented (Phase 1) | `MetricPayload` |
| §17.3.1 | Reserved metric names as `static let` | Implemented (Phase 1) | `StandardMetric.tokensUsed` etc. |
| §18.1 | Error envelope | Implemented (Phase 1) | `ErrorEnvelope` |
| §18.2 | Canonical error taxonomy | Implemented (Phase 1) | `ARCPError` + `ErrorsTests` |
| §18.3 | Retryability flag (`isRetryable`) | Implemented (Phase 1) | `ErrorsTests.retrySemantics` |
| §19   | Resume by `after_message_id` | Phase 5 — not implemented | |
| §19   | Checkpoint-based resume | **Out of scope v0.1** | |
| §20   | MCP compatibility | Future (parallel concept layer) | |
| §21   | Extension registry | Implemented (Phase 1) | `ExtensionRegistry` actor |
| §21.3 | Unknown-message handling | Implemented (Phase 1) | `disposition(forUnknown:optional:)` |
| §22   | WebSocket transport | Phase 6 — not implemented | `vapor/websocket-kit` |
| §22   | stdio transport | Phase 6 — not implemented | NDJSON over stdin/stdout |
| §22   | HTTP/2 transport | **Out of scope v0.1** | |
| §22   | QUIC transport | **Out of scope v0.1** | |

This file is updated at the close of each phase to flip rows to **Implemented**
with a link to the relevant integration test. Phase 7's gate check is that no
in-scope row is still "not implemented".
