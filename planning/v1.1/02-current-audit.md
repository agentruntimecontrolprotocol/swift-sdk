# 02 — Current Swift SDK audit

Honest read of `swift-sdk/` as of 2026-05-14. The conclusion drives
every later phase: **this SDK is on the wrong spec lineage**. The
migration to ARCP v1.1 is not "add the nine v1.1 feature flags" — it
is "replace the wire surface with `draft-arcp-02.md` (v1.0), then add
the nine v1.1 flags on top." Phase 1's "additive vs current Swift"
column already telegraphed this; this audit makes it concrete.

## 0. Headline

| Question                                                                                       | Answer                                                                                                                                                                                                          |
| ---------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Is this SDK on ARCP v1.0 (`draft-arcp-02.md`)?                                                 | **No.** `README.md:5` says "Wire version: 1.0" but the citation in [`RFC-0001-v2.md`](../../RFC-0001-v2.md) points to `draft-arcp-01.md` — a different lineage with HITL, permissions, artifacts as core types. |
| Does the existing message vocabulary match v1.0/v1.1?                                          | **No.** 47 of 53 `MessageType` cases ([`Envelope/MessageType.swift:11-92`](../../Sources/ARCP/Envelope/MessageType.swift#L11-L92)) have no v1.0/v1.1 counterpart.                                                |
| Does the existing envelope shape match §5.1?                                                   | **No.** 11 of the 18 envelope fields ([`Envelope/Envelope.swift:8-26`](../../Sources/ARCP/Envelope/Envelope.swift#L8-L26)) are not in §5.1's set; the canonical `event_seq` field is missing.                    |
| Is strict concurrency mode on?                                                                 | **Yes.** [`Package.swift:5`](../../Package.swift#L5) — `.swiftLanguageMode(.v6)` plus `ExistentialAny` upcoming feature.                                                                                         |
| Does the SDK's Sendable hygiene hold up?                                                       | **Mostly.** One `nonisolated(unsafe)` for the ISO8601 cache (justified). Public types are `Sendable`. No `@unchecked Sendable` audit-debt visible.                                                               |
| Can v1.1 land as additions to the current code?                                                | **No.** The §6.1–§9.6 wire types don't exist; they don't slot into the current types because the existing types embed conflicting assumptions (4-step handshake, lease-per-permission, generic subscriptions).  |

Implication for planning: the milestone sequence in
[`10-synthesis.md`](10-synthesis.md) treats v1.0 alignment as the
load-bearing first three milestones, with v1.1 features as PR-sized
additions on top of a re-spec'd core.

## 1. v1.0 conformance

Compared row-by-row against the v1.0 cells from the TypeScript
[`CONFORMANCE.md`](../../../typescript-sdk/CONFORMANCE.md). Status
values are **Present / Partial / Absent**, scored by wire equivalence
(not by API ergonomics).

### §4. Transport

| §   | Requirement                                | Current  | Where                                                                                            | Notes                                                                                                                |
| --- | ------------------------------------------ | -------- | ------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| 4.1 | WebSocket MUST be supported (`wss`/`/arcp`) | Partial  | [`Transport/WebSocketTransport.swift`](../../Sources/ARCP/Transport/WebSocketTransport.swift)    | Client only. README admits server is partial ("`WebSocketKit.WebSocket`'s server-side initializer is internal").     |
| 4.1 | JSON text frames only                       | Present  | Same                                                                                             | Binary frames not in scope.                                                                                          |
| 4.2 | stdio NDJSON                                | Present  | [`Transport/StdioTransport.swift`](../../Sources/ARCP/Transport/StdioTransport.swift)             |                                                                                                                      |
| 4.3 | Alternate transports MAY exist              | Present  | [`Transport/MemoryTransport.swift`](../../Sources/ARCP/Transport/MemoryTransport.swift)           | In-process test loop. Good shape; survives the rewrite.                                                              |

### §5. Wire Format

| §   | Requirement                                                          | Current | Where                                                                                          | Notes                                                                                                                                                                                                                                  |
| --- | -------------------------------------------------------------------- | ------- | ---------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 5.1 | `arcp` REQUIRED, MUST be `"1"`                                       | Present | [`Envelope/Envelope.swift:9,95`](../../Sources/ARCP/Envelope/Envelope.swift#L9)                |                                                                                                                                                                                                                                        |
| 5.1 | `id` REQUIRED, ULID/UUIDv7                                           | Present | [`Ids/Ulid.swift`](../../Sources/ARCP/Ids/Ulid.swift); `MessageId.random()` mints ULIDs        |                                                                                                                                                                                                                                        |
| 5.1 | `type` REQUIRED                                                      | Present | Encoded out of `MessageType.typeName`                                                          |                                                                                                                                                                                                                                        |
| 5.1 | `session_id` REQUIRED post-welcome                                   | Partial | Envelope holds it optionally; no per-message enforcement                                       | Currently optional everywhere; per-message-schema enforcement is the TS pattern and needs porting.                                                                                                                                     |
| 5.1 | `trace_id` OPTIONAL, W3C 32-hex                                      | Partial | Envelope holds `traceId` ([`Envelope.swift:18`](../../Sources/ARCP/Envelope/Envelope.swift#L18)) | The W3C 32-hex format validator is in [`Trace/TraceContext.swift`](../../Sources/ARCP/Trace/TraceContext.swift); not enforced on decode.                                                                                               |
| 5.1 | `job_id` REQUIRED when applicable                                    | Partial | Same                                                                                           | Optional in the envelope; not gated per message type.                                                                                                                                                                                  |
| 5.1 | `event_seq` REQUIRED on `job.event`/`job.result`/`job.error`         | **Absent** | —                                                                                              | **Critical gap.** No session-scoped monotonic counter. Resumability ([`Store/EventLog.swift`](../../Sources/ARCP/Store/EventLog.swift)) is keyed on `after_message_id`, not `event_seq`. Replacing the resume primitive is a v1.0 task. |
| 5.1 | `payload` REQUIRED                                                   | Present | Yes                                                                                            |                                                                                                                                                                                                                                        |
| 5.1 | Unknown top-level fields MUST be ignored                             | Partial | Swift's `JSONDecoder` ignores unknown keys by default                                          | Will hold; test plan must cover.                                                                                                                                                                                                       |
| 5.1 | **Extra envelope fields not in §5.1**: `timestamp`, `source`, `target`, `stream_id`, `subscription_id`, `span_id`, `parent_span_id`, `correlation_id`, `causation_id`, `idempotency_key`, `priority`, `extensions` | **Present, wrong** | [`Envelope.swift:11-25`](../../Sources/ARCP/Envelope/Envelope.swift#L11-L25)                       | These need to be removed or moved into payloads. `idempotency_key` belongs in `job.submit.payload.idempotency_key`; `priority`/`source`/`target` not in spec; `extensions` not a §5.1 field; span IDs not in the protocol envelope. |
| 5.2 | JSON / UTF-8                                                         | Present | JSON-only encoders/decoders                                                                    |                                                                                                                                                                                                                                        |

### §6. Sessions

The current handshake is the **four-step** model from `draft-arcp-01.md`:
`session.open` → `session.challenge` → `session.authenticate` → `session.accepted`
([`Messages/Session.swift`](../../Sources/ARCP/Messages/Session.swift),
[`Client/ARCPClient.swift:72-82`](../../Sources/ARCP/Client/ARCPClient.swift#L72-L82)).

v1.0/v1.1 use a **two-step** model: `session.hello` → `session.welcome`,
auth carried in `hello.payload.auth.token`. The challenge/nonce
mechanic is absent from v1.0; if needed for JWT replay protection, it
lives at the transport layer or in a vendor extension.

| §   | Requirement                                                          | Current  | Where                                                                                                | Notes                                                                                                                          |
| --- | -------------------------------------------------------------------- | -------- | ---------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| 6.1 | Bearer-token auth on hello                                           | **Absent**  | —                                                                                                    | Auth shape and envelope name both differ. [`Auth/BearerAuth.swift`](../../Sources/ARCP/Auth/BearerAuth.swift) is reusable code, wrong message wrapper. |
| 6.1 | Reject missing/invalid token w/ `session.error` + close              | Partial  | [`Messages/Session.swift:88`](../../Sources/ARCP/Messages/Session.swift#L88) (`SessionRejectedPayload`) | `session.error` envelope name doesn't exist yet; rejection paths emit `session.rejected` instead.                              |
| 6.2 | hello/welcome shape with `capabilities.encodings` + `capabilities.agents` | **Absent**  | —                                                                                                    | Current capability shape (booleans for `streaming`, `durableJobs`, etc.) is incompatible with v1.0 spec — see §2.3 below.       |
| 6.2 | Runtime MUST issue `resume_token` (≥128 bits entropy)                | **Absent**  | —                                                                                                    | No resume_token concept. ULID/Random helpers ([`Ids/Ulid.swift`](../../Sources/ARCP/Ids/Ulid.swift)) work for the credential; the wire surface is new. |
| 6.2 | `resume_token` rotated on every welcome                              | **Absent**  | —                                                                                                    | Same.                                                                                                                          |
| 6.3 | Resume via `session.hello.payload.resume = { session_id, resume_token, last_event_seq }` | **Absent** | —                                                                                                    | Existing resume primitive is `resume` envelope ([`Messages/Control.swift`](../../Sources/ARCP/Messages/Control.swift)) keyed on `after_message_id`. Different shape, different key. |
| 6.3 | Replay events with seq > last_event_seq                              | Partial  | [`Store/EventLog.swift:replay`](../../Sources/ARCP/Store/EventLog.swift)                              | Replay exists but is keyed on message id, not event_seq. Schema change required.                                               |
| 6.3 | `RESUME_WINDOW_EXPIRED` on stale resume                              | **Absent**  | —                                                                                                    | Error code missing in `ErrorCode`.                                                                                             |
| 6.7 | Clean close via `session.bye { reason }`                             | Partial  | `SessionClosePayload` ([`Messages/Session.swift:117`](../../Sources/ARCP/Messages/Session.swift#L117)) | Envelope name is `session.close`, not `session.bye`. Trivial rename.                                                           |

### §7. Jobs

| §   | Requirement                                                          | Current  | Where                                                                                                       | Notes                                                                                                                                                                                              |
| --- | -------------------------------------------------------------------- | -------- | ----------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 7.1 | `job.submit` w/ `agent`/`input`/`lease_request?`/`idempotency_key?`/`max_runtime_sec?` | **Absent** | —                                                                                                           | No `job.submit` envelope. Jobs in this SDK arise from `tool.invoke` ([`Messages/Execution.swift:4`](../../Sources/ARCP/Messages/Execution.swift#L4)). Different model.                              |
| 7.1 | `job.accepted { job_id, lease, accepted_at, parent_job_id?, ... }`   | Partial  | `JobAcceptedPayload` only carries `job_id` ([`Execution.swift:55`](../../Sources/ARCP/Messages/Execution.swift#L55)) | Missing `lease`, `accepted_at`, `parent_job_id`, `delegate_id`, `trace_id`.                                                                                                                          |
| 7.1 | Runtime MAY reduce, MUST NOT expand the lease                        | **Absent**  | —                                                                                                           | Lease subsetting not implemented (no lease on job in the first place).                                                                                                                              |
| 7.2 | Transport-level idempotency via envelope `id`                        | Partial  | EventLog uses message id as a primary key; dedupe falls out of `INSERT OR IGNORE`-style semantics            | Verify the schema. [`Store/Resources/schema.sql`](../../Sources/ARCP/Store/Resources/schema.sql) — confirm during v1.0 milestone.                                                                  |
| 7.2 | Logical idempotency via `payload.idempotency_key` (24h window, same principal → same `job_id`) | **Absent** | —                                                                                                           | Current `idempotency_key` lives on the envelope, not in payload; no replay/duplicate-key path.                                                                                                     |
| 7.2 | `DUPLICATE_KEY` on different agent/input w/ same key                 | **Absent**  | —                                                                                                           |                                                                                                                                                                                                    |
| 7.3 | States `pending`/`running`/`success`/`error`/`cancelled`/`timed_out` | Partial  | `JobState` ([`Execution.swift:165`](../../Sources/ARCP/Messages/Execution.swift#L165)): `accepted/queued/running/blocked/paused/completed/failed/cancelled` | Names differ; semantics overlap. Migration is straightforward.                                                                                                                                      |
| 7.3 | Terminal `job.result` / `job.error` w/ `final_status`                | Partial  | `JobCompletedPayload` / `JobFailedPayload` ([`Execution.swift:113,129`](../../Sources/ARCP/Messages/Execution.swift#L113)) | Wrong envelope names (`job.completed`/`job.failed`), no `final_status` discriminator.                                                                                                                |
| 7.4 | `job.cancel { reason }`, runtime emits `job.error{final_status:"cancelled"}` within 30s | Partial  | `cancel` / `cancel.accepted` / `cancel.refused` envelopes ([`Messages/Control.swift`](../../Sources/ARCP/Messages/Control.swift)) + `JobManager` cancellation paths | Envelope shape and final emission differ.                                                                                                                                                         |

### §8. Job Events

The current SDK emits jobs via a multi-envelope vocabulary
(`job.progress`, `job.heartbeat`, `stream.open`/`stream.chunk`/`stream.close`,
`log`, `metric`, `event.emit`, `trace.span`) rather than a unified
`job.event` carrier with a `kind` discriminator. This is the **single
biggest restructure** in the v1.0 milestone.

| §   | Requirement                                                          | Current   | Where                                                                                                | Notes                                                                                                                                |
| --- | -------------------------------------------------------------------- | --------- | ---------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| 8.1 | Single `job.event` w/ `payload.kind`/`payload.ts`/`payload.body`     | **Absent**   | —                                                                                                    | Replaces the 7+ envelope types above with one wrapper.                                                                               |
| 8.2 | Eight v1.0 kinds: `log`, `thought`, `tool_call`, `tool_result`, `status`, `metric`, `artifact_ref`, `delegate` | Partial   | The kinds exist as separate envelopes; `tool.invoke`/`tool.result` are the closest analogues of `tool_call`/`tool_result` | They need to become event bodies under `job.event`.                                                                                  |
| 8.2 | `tool_call.body.call_id` links call/result                           | Partial   | [`Execution.swift:4`](../../Sources/ARCP/Messages/Execution.swift#L4) — no `call_id` on `ToolInvokePayload` | Add `call_id` during the event-envelope migration.                                                                                   |
| 8.2 | Vendor namespace `x-vendor.kind`; unknown kinds ignored              | Partial   | [`Extensions/ExtensionRegistry.swift`](../../Sources/ARCP/Extensions/ExtensionRegistry.swift) and `MessageType.unknown` handle vendor envelopes; the rule must move to kinds. |                                                                                                                                      |
| 8.3 | Sequence numbers SESSION-scoped, monotonic, gap-free across reconnects | **Absent**   | —                                                                                                    | Adding `event_seq` is the same task as §5.1 above.                                                                                   |

### §9. Leases

The current model is **lease-per-permission/resource/operation** with
explicit grant/refresh/revoke/expire envelopes
([`Runtime/LeaseManager.swift`](../../Sources/ARCP/Runtime/LeaseManager.swift)).
v1.0 leases are **immutable, granted at submit, per-job, capability→pattern[]**.

| §   | Requirement                                                          | Current  | Where                                                                                                | Notes                                                                                                                                  |
| --- | -------------------------------------------------------------------- | -------- | ---------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| 9.1 | Immutable lease; granted at submit; capability → glob patterns      | **Absent**  | —                                                                                                    | Replace `LeaseManager` with a v1.0 lease compiler + per-op validator. Salvage: ULIDs, store backbone.                                  |
| 9.2 | Reserved namespaces `fs.read`, `fs.write`, `net.fetch`, `tool.call`, `agent.delegate`, `cost.budget` | **Absent**  | —                                                                                                    | The whole capability/pattern grammar is new.                                                                                           |
| 9.2 | Glob `*` (single segment) / `**` (zero+ segments); anchored          | **Absent**  | —                                                                                                    | New compiler. Swift's `FileManager` glob is wrong shape; this is a string-pattern compiler ported from TS.                            |
| 9.3 | Runtime MUST validate every op; `PERMISSION_DENIED` on fail          | **Absent**  | —                                                                                                    | New surface (`validateLeaseOp`).                                                                                                       |
| 9.4 | Lease subsetting for delegation                                      | **Absent**  | —                                                                                                    |                                                                                                                                        |
| 14  | Canonicalize paths/URLs before glob check                            | **Absent**  | —                                                                                                    | Path canonicalization on Linux vs Darwin diverges (`realpath`, `URL(fileURLWithPath:)`); plan a `canonicalizeTarget` helper.           |

### §10. Delegation

| §    | Requirement                                                                                                                       | Current  | Notes                                                                                                                                                                                  |
| ---- | --------------------------------------------------------------------------------------------------------------------------------- | -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 10.1 | Delegation as `job.event` w/ `kind: "delegate"` carrying `{delegate_id, agent, input, lease_request, lease_constraints?}`         | **Absent**  | Mention in `RESERVED_EVENT_KINDS`. The current SDK README lists "multi-agent delegation/handoff" as out of scope for v0.1.                                                              |
| 10.2 | Runtime responds with `job.accepted { job_id, parent_job_id, delegate_id, lease }`                                                | **Absent**  |                                                                                                                                                                                        |
| 10.3 | Delegated jobs inherit parent `trace_id`; new span MAY be created                                                                 | Partial  | TraceContext exists ([`Trace/TraceContext.swift`](../../Sources/ARCP/Trace/TraceContext.swift)); the delegate path is missing.                                                          |

### §11. Trace Propagation

| §   | Requirement                                                                                                                         | Current  | Where                                                                                | Notes                                                                                                                                |
| --- | ----------------------------------------------------------------------------------------------------------------------------------- | -------- | ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------ |
| 11  | `trace_id` is W3C 32-hex; client SHOULD include on submit; runtime MUST mint if absent, echo on `job.accepted.payload.trace_id`     | Partial  | [`Trace/TraceContext.swift`](../../Sources/ARCP/Trace/TraceContext.swift) validates W3C 32-hex | Mint-if-absent is unimplemented because there is no `job.submit`/`job.accepted` surface to mint into.                                |
| 11  | Runtime SHOULD emit OTel spans w/ `arcp.session_id`, `arcp.job_id`, `arcp.agent`, `arcp.lease.capabilities`                         | **Absent**  | —                                                                                    | No tracing exporter wiring. v1.1 adds two more attribute names; treat as one task.                                                  |

### §12. Error Taxonomy

Current canonical set is gRPC-style ([`Errors/ErrorCode.swift:6`](../../Sources/ARCP/Errors/ErrorCode.swift#L6))
with extras for `HEARTBEAT_LOST`, `LEASE_EXPIRED`, `LEASE_REVOKED`,
`BACKPRESSURE_OVERFLOW`. v1.0/v1.1 want a different 12+3-code set.

| v1.0/v1.1 code                | Current presence                                                                                                                                            |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PERMISSION_DENIED`           | Present (`.permissionDenied`)                                                                                                                               |
| `LEASE_SUBSET_VIOLATION`      | **Absent**                                                                                                                                                  |
| `JOB_NOT_FOUND`               | Partial — `.notFound` is generic                                                                                                                            |
| `DUPLICATE_KEY`               | Partial — `.alreadyExists` is the closest                                                                                                                   |
| `AGENT_NOT_AVAILABLE`         | **Absent**                                                                                                                                                  |
| `CANCELLED`                   | Present (`.cancelled`)                                                                                                                                      |
| `TIMEOUT`                     | Partial — `.deadlineExceeded`                                                                                                                               |
| `RESUME_WINDOW_EXPIRED`       | **Absent**                                                                                                                                                  |
| `HEARTBEAT_LOST`              | Present (`.heartbeatLost`)                                                                                                                                  |
| `INVALID_REQUEST`             | Partial — `.invalidArgument`                                                                                                                                |
| `UNAUTHENTICATED`             | Present (`.unauthenticated`)                                                                                                                                |
| `INTERNAL_ERROR`              | Partial — `.internal`                                                                                                                                       |
| **v1.1** `LEASE_EXPIRED`      | Present (`.leaseExpired`) — but bound to the per-permission lease, not §9.5's `expires_at`                                                                  |
| **v1.1** `BUDGET_EXHAUSTED`   | **Absent**                                                                                                                                                  |
| **v1.1** `AGENT_VERSION_NOT_AVAILABLE` | **Absent**                                                                                                                                         |

Plan: replace the gRPC-style enum entirely with a v1.1 closed
15-case enum carrying associated values for structured context.
Mapping decoders accept both old and new wire strings during a brief
deprecation window (or just hard cut, since this SDK has no released
consumers per [`README.md:8`](../../README.md#L8) — confirm before
committing to hard cut).

## 2. Package, platforms, concurrency

### 2.1 Package.swift decoded

[`Package.swift`](../../Package.swift):

- **Tools version:** `swift-tools-version: 6.1`.
- **Platforms:** `macOS(.v14)`. **No Linux declaration** — the
  SwiftPM Linux build is implicit but no `.linux` toolchain test runs.
- **Products:** one library `ARCP`, one executable `arcp` (CLI).
- **Targets:** single `ARCP` target with everything; one
  `executableTarget` for the CLI; one `testTarget` `ARCPTests`. **No
  module split** between core/client/runtime/middleware. Targets to
  recommend (see [`04-architecture.md`](04-architecture.md)):
  `ARCPCore`, `ARCPClient`, `ARCPRuntime`, optional `ARCPMiddleware*`.
- **Dependencies:**
  | Dep                       | Pin                | Purpose                            | Verdict for v1.1                                                                                                      |
  | ------------------------- | ------------------ | ---------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
  | `swift-log`               | from 1.6.0         | Logging                            | Keep.                                                                                                                 |
  | `swift-argument-parser`   | from 1.5.0         | CLI                                | Keep (CLI target only).                                                                                               |
  | `swift-nio`               | from 2.74.0        | WS server primitives               | Keep, but pull through middleware target only. Core/Client shouldn't depend on NIO transitively.                      |
  | `websocket-kit`           | from 2.15.0        | WS client                          | Reassess in [`03-libraries.md`](03-libraries.md). The "server-side initializer is internal" footgun is real.          |
  | `jwt-kit`                 | `5.1.0..<5.3.0`    | JWT auth                           | **Drop or move to a middleware target.** v1.0/v1.1 auth is bearer-token; JWT is a runtime concern, not core/client. Pin justification is real (Swift 6.2 floor pull-in via MLDSA) but irrelevant if we drop the dep. |
  | `SQLite.swift`            | from 0.15.3        | EventLog persistence               | **Drop from default build.** v1.0 resume buffer is in-memory by default ([§14 says "purge at window expiry"](../../../spec/docs/draft-arcp-02.1.md#L1199)); SQLite is a runtime-opt-in. |
  | `swift-format`            | from 600.0.0       | Format plugin                      | Keep as dev plugin.                                                                                                   |
  | `swift-docc-plugin`       | from 1.4.0         | Docs                               | Keep.                                                                                                                 |
- **Swift settings:** `.swiftLanguageMode(.v6)`, `ExistentialAny`.
  Strict concurrency is **on** by virtue of v6 language mode.
- **Resources:** one resource (`Store/Resources/schema.sql`) — moves
  out of core when SQLite is removed from default deps.

### 2.2 Platforms

`macOS(.v14)` only. The bootstrap (line 88–124 of
[`../../BOOTSTRAP.md`](../../BOOTSTRAP.md)) targets **macOS 14+ /
Linux / iOS 17+**. Adding the iOS floor is one Package.swift line; the
Linux floor is implicit but should be CI-verified
(see [`07-tests.md`](07-tests.md)).

A subtle gotcha: `URLSessionWebSocketTask` is available on
macOS 10.15+/iOS 13+ but on Linux only via swift-corelibs-foundation
which historically lagged. Phase 3 ([`03-libraries.md`](03-libraries.md))
decides whether we depend on it for the client transport.

### 2.3 Sendable / actor isolation status

Spot check across the major files:

| Type / file                                                                                                                  | Isolation  | Sendable    | Notes                                                                                                                                                                  |
| ---------------------------------------------------------------------------------------------------------------------------- | ---------- | ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Envelope` ([`Envelope/Envelope.swift:8`](../../Sources/ARCP/Envelope/Envelope.swift#L8))                                    | value type | Sendable    | All stored properties are Sendable. Manual Codable. Holds enum payloads which are Sendable.                                                                            |
| `MessageType` ([`Envelope/MessageType.swift:11`](../../Sources/ARCP/Envelope/MessageType.swift#L11))                          | enum       | Sendable    | All payloads Sendable.                                                                                                                                                 |
| `ARCPRuntime` ([`Runtime/ARCPRuntime.swift:10`](../../Sources/ARCP/Runtime/ARCPRuntime.swift#L10))                            | actor      | n/a         | Holds dictionaries of sessions/jobs; correct.                                                                                                                          |
| `JobManager` ([`Runtime/JobManager.swift`](../../Sources/ARCP/Runtime/JobManager.swift))                                     | actor      | n/a         | 641 lines — single biggest piece of runtime logic; survives the rewrite in spirit (per-session job table) but the wire-emission methods all need new envelopes.        |
| `LeaseManager` ([`Runtime/LeaseManager.swift`](../../Sources/ARCP/Runtime/LeaseManager.swift))                                | actor      | n/a         | Throwaway in the v1.0 migration — wrong model.                                                                                                                         |
| `SubscriptionManager` ([`Runtime/SubscriptionManager.swift`](../../Sources/ARCP/Runtime/SubscriptionManager.swift))           | actor      | n/a         | Generic firehose with multi-key filter; v1.1 subscribe is per-job. Rebuild.                                                                                            |
| `ARCPClient` ([`Client/ARCPClient.swift:8`](../../Sources/ARCP/Client/ARCPClient.swift#L8))                                  | actor      | n/a         | Owns continuations + AsyncStream — clean shape. The handshake/auth pieces change; the actor harness stays.                                                             |
| `Transport` ([`Transport/Transport.swift`](../../Sources/ARCP/Transport/Transport.swift))                                    | protocol   | Sendable    | Sound shape.                                                                                                                                                           |
| `Mailbox` ([`Runtime/Mailbox.swift`](../../Sources/ARCP/Runtime/Mailbox.swift))                                              | actor      | Sendable    | 42 lines, minimal. AsyncSequence backbone; survives.                                                                                                                   |
| ISO8601 cache ([`Envelope.swift:191,197`](../../Sources/ARCP/Envelope/Envelope.swift#L191))                                  | static     | `nonisolated(unsafe)` | Documented justified (configure-once, then read-only). Safe.                                                                                                          |

**No `@unchecked Sendable` lurks.** No `DispatchQueue` on public
surface. No `@MainActor` in core. The concurrency baseline is good;
the rewrite preserves it.

### 2.4 Strict-concurrency posture

`.swiftLanguageMode(.v6)` is the strongest available. The audit found
no `-strict-concurrency=…` flags suppressed and no `@unchecked` debt.
Treat the existing baseline as the floor; do not regress when adding
v1.1 types.

One thing to add during the rewrite: the `Feature` enum (§3 of
[`01-spec-delta.md`](01-spec-delta.md)) needs `Sendable` + `Hashable`
explicitly, and the negotiated `Set<Feature>` passed across actor
boundaries needs to be wrapped in a Sendable struct or fed via
parameters, not via an actor-isolated property accessed from the
client side.

## 3. Gap matrix — v1.1 feature × {missing/partial/present}

Single table; each row carries: target module (assuming the
[`04-architecture.md`](04-architecture.md) split), risk (L/M/H), and
the Swift-specific reason for the risk where it isn't generic.

| v1.1 feature       | Spec § | Status (vs current Swift) | Target module                          | Risk | Swift-specific concern (where it isn't generic)                                                                                                                                                          |
| ------------------ | ------ | ------------------------- | -------------------------------------- | ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Capability negotiation w/ `features[]` | §6.2   | missing | `ARCPCore.Capabilities` + intersection helper | **L** | `Feature` enum cases cannot contain `.` — need `RawRepresentable` mapping (`costBudget` → `cost.budget`). Negotiated `Set<Feature>` must be Sendable across the client actor boundary.                  |
| Rich agent inventory                  | §6.2   | missing | `ARCPCore.Messages.Session`            | **L** | Welcome's `agents` field is a union (`[String]` vs `[{name,versions,default?}]`). Manual `Codable` with a `try?` on the rich shape, fallback to flat.                                                   |
| `heartbeat`                           | §6.4   | partial | `ARCPCore.Messages.Session` (envelope) + `ARCPRuntime.Session` (timer) | **M** | Existing `PingPayload`/`PongPayload` exist but with different bodies. Need new `SessionPingPayload`/`SessionPongPayload`. `ContinuousClock` for monotonic interval ticks (not `Date`). `nonisolated(unsafe)` not required if the timer lives on the session actor. |
| `ack`                                 | §6.5   | missing | `ARCPCore.Messages.Session` + `ARCPRuntime.Session.recordAck` + `ARCPClient.autoAck` | **L** | Auto-ack coalescing: combine `for await event in stream` with a debounce. Swift idiom: `AsyncStream` + `Task` running every N events / M ms; avoid `Timer`.                                              |
| `list_jobs`                           | §6.6   | missing | `ARCPCore.Messages.Session` + `ARCPRuntime.handleListJobs`             | **L** | Filter + cursor types are straightforward `Codable` structs. Cursor opacity is a runtime concern.                                                                                                       |
| `subscribe`                           | §7.6   | missing (existing surface is wrong shape) | `ARCPClient.subscribe` + `ARCPRuntime.handleJobSubscribe` | **H** | **`AsyncStream` lifecycle across actor hops.** A subscription holds a continuation; if the subscribing client is dropped while events are mid-flight, the runtime must detect closure (via `onTermination` on the source stream) and free the runtime-side subscriber entry. v1.0 will be tempted to leak. |
| Agent versioning                      | §7.5   | missing | `ARCPCore.parseAgentRef`               | **L** | `name@version` parser; the grammar is regexable in Swift.                                                                                                                                                |
| `lease_expires_at`                    | §9.5   | partial (wrong shape) | `ARCPCore.LeaseConstraints` + `ARCPRuntime.LeaseEvaluator` | **M** | **Swift's `Date` is not monotonic.** Use `ContinuousClock`/`SuspendingClock` for elapsed-time checks; use `Date` only for serializing `expires_at`. Spec §14 explicitly requires "monotonic NTP-disciplined clock". Test plan must cover wall-clock jumps. |
| `cost.budget`                         | §9.6   | missing | `ARCPCore.Budget` + `ARCPRuntime.LeaseEvaluator` + `ARCPRuntime.Job.applyCostMetric` | **M** | `Decimal` (not `Double`) for amounts. `Decimal` arithmetic in Swift is not Sendable-pure (it's a value type, fine), but cross-actor reads on `budgetRemaining` need a snapshot copy.                    |
| `progress` event kind                 | §8.2.1 | partial (wrong shape) | `ARCPCore.Messages.Event`              | **L** | Current `JobProgressPayload` uses `percent: Double` — new kind is `{current, total?, units?, message?}`. Replace, not extend.                                                                            |
| `result_chunk`                        | §8.4   | missing | `ARCPCore.Messages.Event` + `ARCPClient.JobHandle.collectChunks` | **H** | **Chunk assembly buffer**. Up to 256 MiB total (spec §14 cap). Naïve `String` concatenation in a `for try await` loop is O(n²) — use `Data` accumulator with `reserveCapacity`. Watch for actor reentrancy if the collector lives in `ARCPClient`. |
| Lease subsetting (budget + expiry)    | §9.4   | missing | `ARCPRuntime.LeaseEvaluator.isLeaseSubset` | **M** | Per-currency `Decimal` arithmetic; `min(child.expiresAt, parent.expiresAt)` on `Date`.                                                                                                                  |
| Tracing attributes                    | §11    | missing | `ARCPMiddlewareOTel`                   | **L** | Need OTel-Swift; see [`03-libraries.md`](03-libraries.md) for the pick.                                                                                                                                 |
| New error codes (3)                   | §12    | missing | `ARCPCore.ARCPError`                   | **L** | Closed enum; computed `retryable` returns `false` for all three.                                                                                                                                        |

**H-risk rationale recap:**

- `subscribe`: AsyncStream lifecycle across actor hops needs explicit
  `onTermination` to close runtime-side subscriber entries when the
  client drops the stream; this is a known Swift bug-bait.
- `result_chunk`: cap+accumulator semantics need careful Data
  arithmetic and reentrancy discipline on `ARCPClient`.

Everything else is L or M risk because the wire surface and Swift
idiom map cleanly; the per-feature size is small once the v1.0
foundation lands.

## 4. Salvage list — what survives the migration

Not everything is throwaway. The following pieces hold up:

| Piece                                                                                                                  | Why it survives                                                                                                                                                                                  |
| ---------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| [`Ids/Ulid.swift`](../../Sources/ARCP/Ids/Ulid.swift) + [`Ids/Ids.swift`](../../Sources/ARCP/Ids/Ids.swift)              | ULID generator is spec-shaped (§5.1 accepts ULID or UUIDv7); the typed-id newtypes pattern is exactly the Swift idiom we want.                                                                  |
| [`Transport/Transport.swift`](../../Sources/ARCP/Transport/Transport.swift)                                              | Protocol surface is right (Sendable + send/receive). Concrete transports (memory/stdio) survive verbatim.                                                                                       |
| [`Transport/MemoryTransport.swift`](../../Sources/ARCP/Transport/MemoryTransport.swift)                                  | In-process test loop. Used by every example. Survives.                                                                                                                                          |
| [`Transport/StdioTransport.swift`](../../Sources/ARCP/Transport/StdioTransport.swift)                                    | NDJSON framing is unchanged. Survives.                                                                                                                                                          |
| [`Runtime/Mailbox.swift`](../../Sources/ARCP/Runtime/Mailbox.swift)                                                      | 42-line generic queue; survives.                                                                                                                                                                |
| [`Runtime/JobContext.swift`](../../Sources/ARCP/Runtime/JobContext.swift)                                                | The per-job context protocol concept survives; the methods it exposes (`progress`, `streamResult`, `delegate`) change to match TS `JobContext`.                                                  |
| [`Runtime/JobManager.swift`](../../Sources/ARCP/Runtime/JobManager.swift) — **skeleton only**                            | The per-session job table, cancellation propagation, and 30s grace period concepts survive. The emission methods (which produce `job.started`, `job.heartbeat`, etc.) are rewritten.            |
| [`Trace/TraceContext.swift`](../../Sources/ARCP/Trace/TraceContext.swift)                                                | W3C 32-hex validation survives. The propagation rules update.                                                                                                                                   |
| [`Extensions/ExtensionRegistry.swift`](../../Sources/ARCP/Extensions/ExtensionRegistry.swift)                            | The `x-vendor.*` namespace classifier survives; the registry mounts at the kind level now, not the envelope-type level.                                                                          |
| `Package.swift` Swift-6 language-mode + `ExistentialAny` settings                                                       | The strict-concurrency baseline stays.                                                                                                                                                          |
| [`Tests/ARCPTests/`](../../Tests/ARCPTests/)                                                                             | Harness structure survives; most cases are rewritten because the message types change. The infrastructure (XCTest helpers, time-injection patterns) is salvageable.                            |

**Throwaway:**
[`Runtime/LeaseManager.swift`](../../Sources/ARCP/Runtime/LeaseManager.swift),
[`Runtime/SubscriptionManager.swift`](../../Sources/ARCP/Runtime/SubscriptionManager.swift) (rebuild
for v1.1 shape),
[`Messages/Human.swift`](../../Sources/ARCP/Messages/Human.swift),
[`Messages/Permissions.swift`](../../Sources/ARCP/Messages/Permissions.swift),
[`Messages/Artifacts.swift`](../../Sources/ARCP/Messages/Artifacts.swift),
[`Messages/Streaming.swift`](../../Sources/ARCP/Messages/Streaming.swift),
[`Messages/Subscriptions.swift`](../../Sources/ARCP/Messages/Subscriptions.swift),
[`Messages/Control.swift`](../../Sources/ARCP/Messages/Control.swift) (cancel/interrupt/resume
shapes), parts of [`Messages/Execution.swift`](../../Sources/ARCP/Messages/Execution.swift)
(tool.invoke/result envelopes), the 4-step session handshake
([`Messages/Session.swift`](../../Sources/ARCP/Messages/Session.swift)),
[`Auth/JWTAuth.swift`](../../Sources/ARCP/Auth/JWTAuth.swift) (move out
of core), [`Store/EventLog.swift`](../../Sources/ARCP/Store/EventLog.swift)
(SQLite event log — replace with in-memory ring; SQLite becomes an
opt-in `ARCPStoreSQLite` target).

## 5. Strict-concurrency planning items (for [`04-architecture.md`](04-architecture.md))

- The negotiated `Set<Feature>` is read by `ARCPClient` from the
  `ARCPRuntime`'s welcome reply. After connect it's immutable, so
  hold it as `let` on the client actor, not as a computed property.
- Pending-continuation tables on `ARCPClient`
  ([`Client/ARCPClient.swift:15-17`](../../Sources/ARCP/Client/ARCPClient.swift#L15-L17))
  must remain actor-isolated. Resist the temptation to expose them via
  unstructured `Task` callbacks; use `withCheckedContinuation` /
  `withTaskCancellationHandler`.
- `subscribe` returns `AsyncThrowingStream<JobEvent, Error>`. The
  stream's continuation is created with `bufferingPolicy:
  .bufferingNewest(N)` so a slow consumer can't OOM the client. On
  `onTermination`, the runtime-side subscriber entry must be freed —
  the architecture plan owns this contract.
- The cost-budget counter is `Decimal` (Sendable, value type). It
  lives on the per-job actor; reads from `JobContext.budget` return a
  snapshot copy.
- The lease-expiry clock decision (use `ContinuousClock` for elapsed,
  `Date` for serialization) is enforced in
  [`04-architecture.md`](04-architecture.md) — the audit just flags
  that `Date(timeIntervalSinceNow:)` in the current LeaseManager
  ([`LeaseManager.swift:49,83`](../../Sources/ARCP/Runtime/LeaseManager.swift#L49))
  is on the wrong clock.

## 6. What this means for the next phase

The Phase 3–9 prompts in [`../../BOOTSTRAP.md`](../../BOOTSTRAP.md)
assume v1.0 alignment is "already there." It isn't. The
[`04-architecture.md`](04-architecture.md) prompt and
[`10-synthesis.md`](10-synthesis.md) milestone ordering need to fold
in **"Milestone 0: v1.0 wire alignment"** before any of the nine v1.1
feature flags. The synthesis prompt explicitly resolves this
contradiction.

The other knock-on: examples in [`06-examples.md`](06-examples.md)
will mirror the **23 TS examples** (9 v1.0 + 9 v1.1 + 5 host), not
just the 18 v1.1 examples the bootstrap originally implied. The TS
[`CONFORMANCE.md`](../../../typescript-sdk/CONFORMANCE.md) §13 table
is the source of truth for the example list.
