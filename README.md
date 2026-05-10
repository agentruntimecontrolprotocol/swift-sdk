# ARCP — Swift SDK

Swift 6 reference implementation of the **Agent Runtime Control Protocol**
([RFC 0001 v2](RFC-0001-v2.md)). Wire version: **1.0**. SDK version: **0.1.0**.

## Status

v0.1.0 — protocol fundamentals across the seven gated phases:

- ✅ Envelope, ids (ULID), errors, extension registry, SQLite event log
- ✅ Four-step handshake (RFC §8.1) with `bearer`, `signed_jwt`, `none` schemes
- ✅ Capability negotiation (RFC §7)
- ✅ Durable jobs with state machine, heartbeats, cooperative cancellation, interrupts
- ✅ Multi-kind streams (text, event, log, thought, metric, base64 binary) + backpressure
- ✅ Human-in-the-loop primitives with first-response-wins resolution and default fallback
- ✅ Permission challenges + lease lifecycle (grant, refresh, revoke, expire sweep)
- ✅ Subscriptions with filter, backfill, `subscription.backfill_complete` boundary
- ✅ Inline-base64 artifacts with retention sweep
- ✅ Resume by `after_message_id`
- ✅ Transports: `MemoryTransport` (tests), `StdioTransport` (NDJSON), `WebSocketTransport` (client)

Out of scope for v0.1 (see [`CONFORMANCE.md`](CONFORMANCE.md)): mTLS / OAuth2 auth,
sidecar binary stream frames, scheduled jobs, multi-agent delegation/handoff,
trust elevation, checkpoint-based resume, full WebSocket server (the client
transport works; server is partial because `WebSocketKit.WebSocket`'s
server-side initializer is internal — full server lands in v0.2).

## Requirements

- Swift 6.0 toolchain or later (validated against 6.3.1)
- macOS 14+ or Linux (Ubuntu 22.04+ tested)

## Quickstart

```bash
git clone <this repo>
cd swift-sdk
swift run sample-01-minimal-session
```

Expected output:
```
Sample 01 — minimal session (wire 1.0)
session opened: sess_01...
pong nonce: hello
session closed
```

The other five samples — `sample-02-tool-invoke-progress`,
`sample-03-human-input-request`, `sample-04-permission-challenge`,
`sample-05-observer-subscription`, `sample-06-relay-human-in-the-loop` — each
demonstrate a distinct ARCP surface end-to-end via the in-memory transport.

## CLI

```bash
swift run arcp serve              # accept one ARCP session over stdio
swift run arcp send <tool> --args '{"k":"v"}'
swift run arcp tail               # subscribe and print events
swift run arcp replay <db> <session>
```

## Build & test (gate command set)

The seven phases of v0.1 each pass these five commands at exit code 0:

```bash
swift package plugin --allow-writing-to-package-directory format-source-code
swift package plugin lint-source-code -- --strict
swift build -c release -Xswiftc -warnings-as-errors
swift test --parallel --enable-code-coverage
swift package generate-documentation --target ARCP
```

## Architecture

```
+------------------------------------------------------------+
|                     ARCPRuntime  (server)                  |
|  +------------+  +-------------+  +--------------------+   |
|  | EventLog   |  | Subscription|  | ArtifactStore      |   |
|  | (SQLite)   |  | Manager     |  | (SQLite blobs)     |   |
|  +------------+  +-------------+  +--------------------+   |
|  Per-session:                                              |
|    JobManager  →  StreamManager, LeaseManager,             |
|                   PendingRegistry × {HITL, choice, perm}   |
|  Auth:           BearerAuthValidator | JWTAuthValidator    |
+------------------------------------------------------------+
                            |
                            | Envelope (RFC §6.1, JSON)
                            v
+------------------------------------------------------------+
|              Transport (RFC §22 — Sendable)                |
|  MemoryTransport (tests)  StdioTransport  WebSocketTransport
+------------------------------------------------------------+
                            |
                            v
+------------------------------------------------------------+
|                     ARCPClient  (client)                   |
|  invoke(), ping(), send(); HumanInputHandler,              |
|  PermissionHandler — async dispatch via Mailbox actor.     |
+------------------------------------------------------------+
```

State diagrams for sessions, jobs, streams, subscriptions, and leases live in
[`PLAN.md`](PLAN.md) §6.

## RFC mapping

[`PLAN.md`](PLAN.md) §5 maps every in-scope wire message type to its
`MessageType` enum case and payload struct. Out-of-scope types decode as
`.unknown(typeName:payload:)` and are rejected per RFC §21.3 with `UNIMPLEMENTED`
when a non-optional sender expects them.

## License

Apache License 2.0 — see [`LICENSE`](LICENSE) in this directory.
