# 10 — Synthesis

Synthesis of phases 1–9 into an executable migration plan. This file
resolves contradictions between sibling plans, orders the work into
PR-sized milestones, calls out load-bearing risks, and closes with
open questions that need a human decision before kickoff.

## 1. Executive summary

**The Swift SDK is not on ARCP v1.0.** Per [`02-current-audit.md`](02-current-audit.md)
§0, the current code targets `draft-arcp-01.md` (a different protocol
lineage with HITL, permissions, artifacts as core types). The
[`README.md`](../../README.md) line "Wire version: 1.0" refers to
that lineage, not `draft-arcp-02.md` (the v1.0 surface v1.1 is
additive over).

**Therefore the migration is not "add nine feature flags."** It is
"replace the v1.0 wire surface, then add the nine v1.1 features on
top." The size of the work is dominated by v1.0 alignment (Milestones
1–2 below); each v1.1 feature is then a small, mostly independent PR
(Milestone 3).

**The target end state** mirrors `typescript-sdk/packages/{core,client,runtime,sdk}`
plus three host adapters and the OTel middleware. SwiftPM targets:
`ARCPCore`, `ARCPClient`, `ARCPRuntime`, umbrella `ARCP`,
`ARCPWebSocketClient` (transport-isolation, per [`04-architecture.md`](04-architecture.md)
§1), `ARCPStoreSQLite` (opt-in), `ARCPVapor`, `ARCPHummingbird`,
`ARCPNIO`, `ARCPOTel`. Floor platforms: macOS 14, Linux Swift 6.x,
iOS 17 (per BOOTSTRAP). Swift 6 language mode is already on.

**Headline numbers:**

- ≈ **47 of 53** existing `MessageType` cases are deleted or renamed
  ([`02-current-audit.md`](02-current-audit.md) §0).
- ≈ **11 of 18** envelope fields are dropped or moved into payloads.
- **22 examples**, not 18 (audit §6; [`06-examples.md`](06-examples.md) §1).
- **15-code** canonical error set (12 v1.0 + 3 v1.1) replacing the
  current gRPC-style 21-code enum.
- **Coverage floor:** 87% lines + `functions ≥ 90%` ([`07-tests.md`](07-tests.md) §5).

## 2. Contradictions resolved

Each row is a place where two plans disagreed (or one plan extended a
peer). The synthesis decides.

| #  | Disagreement                                                                                                                                                                                                              | Decision                                                                                                                                                                                                                                                                          |
| -- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1  | Middleware target count. [`04-architecture.md`](04-architecture.md) §1 lists three middleware targets (`ARCPVapor`, `ARCPHummingbird`, `ARCPOTel`); [`05-middleware.md`](05-middleware.md) §0 + §4 list four (adds `ARCPNIO`). | **Four.** `ARCPNIO` is the framework-free seam (Swift twin of `@arcp/node`). [`05-middleware.md`](05-middleware.md) is authoritative for the middleware roster; [`04-architecture.md`](04-architecture.md) row labelled "middleware" expands to all four.                          |
| 2  | Example count. [`02-current-audit.md`](02-current-audit.md) §6 says 23; BOOTSTRAP Phase 6 says 18; [`06-examples.md`](06-examples.md) §1 settles on 22.                                                                     | **22.** `bun/` has no Swift twin (Bun's `Bun.serve` upgrade API is JS-runtime-specific); the other v1.0/v1.1/host examples all map. [`06-examples.md`](06-examples.md) is authoritative.                                                                                            |
| 3  | WebSocket client transport target placement. [`03-libraries.md`](03-libraries.md) implies WS client lives in `ARCPClient`; [`04-architecture.md`](04-architecture.md) §1 isolates it in `ARCPWebSocketClient`.            | **Separate `ARCPWebSocketClient` target.** Reason per [`04-architecture.md`](04-architecture.md): isolating `URLSessionWebSocketTask`/`websocket-kit` to its own target makes the platform-specific dep swap a one-line `Package.swift` change.                                  |
| 4  | TS `@arcp/middleware-otel` traceparent source. The original Phase 5 prompt said "extract from upgrade-request headers"; [`05-middleware.md`](05-middleware.md) §2 (`ARCPOTel`) extracts from envelope `extensions["x-vendor.opentelemetry.tracecontext"]`. | **Envelope extensions, not upgrade headers.** [`05-middleware.md`](05-middleware.md) cites `typescript-sdk/packages/middleware/otel/src/index.ts:L48`. This is a documented gotcha; the docs PR (Milestone 6) calls it out under `ARCPOTel`.                                       |
| 5  | DocC topic shape for `JobSubscription` vs `Job`. [`04-architecture.md`](04-architecture.md) §4 makes them two distinct types (no shared protocol); [`08-docs-readme.md`](08-docs-readme.md) §2 groups them under one DocC topic. | **Two types, one DocC topic ("Job handles").** The type-system rule prevents subscribers from cancelling (§7.6); the DocC topic surfaces both side by side so the difference is immediately obvious to a reader.                                                                  |
| 6  | Frontmatter on `docs/`. TS site does not ship frontmatter today ([`08-docs-readme.md`](08-docs-readme.md) §1, verified against `typescript-sdk/docs/`); Swift adopts it.                                                  | **Adopt frontmatter on Swift `docs/`, file a follow-up to backfill TS.** Reason: the shared docs site needs the `sdk:` discriminator to render both side by side. The TS backfill is out of scope for this SDK; one cross-repo issue tracks it ([open questions §6](#6-open-questions)). |
| 7  | Coverage substitute metric. [`07-tests.md`](07-tests.md) picks `functions ≥ 90%`; BOOTSTRAP wanted "the substitute metric documented." Done.                                                                              | **`functions ≥ 90%`** is the substitute. Confirmed by [`07-tests.md`](07-tests.md) §5; documented in `CONFORMANCE.md` test-coverage section (Milestone 6).                                                                                                                          |
| 8  | `ARCPStoreSQLite` opt-in target — is it shipped in v1.1.0? [`03-libraries.md`](03-libraries.md) and [`04-architecture.md`](04-architecture.md) keep it on the roster; v1.1 spec does not require persistence.            | **Shipped but not exercised by default.** In-memory resume buffer is the default in `ARCPRuntime`; `ARCPStoreSQLite` is one PR (Milestone 4F) that wires the SQLite-backed event log already in `Store/EventLog.swift`. Strictly opt-in; no v1.1 examples depend on it.            |
| 9  | Targets in `target-dependency.dot` vs Phase 4 roster. [`09-diagrams.md`](09-diagrams.md) §1.1 lists targets from BOOTSTRAP verbatim; [`04-architecture.md`](04-architecture.md) §1 has a final roster.                  | **Diagram targets match [`04-architecture.md`](04-architecture.md) §1 final roster.** Update the `.dot` skeleton in the diagrams PR to add `ARCPWebSocketClient` and `ARCPStoreSQLite` (both as dashed-edge optional dependencies of `ARCPClient` / `ARCPRuntime` respectively).      |

## 3. Milestone ordering (PR-sized)

Each milestone is one PR unless explicitly subdivided. PRs are
ordered by dependency. Approximate sizes assume Swift-fluent reviewer
bandwidth and an empty calendar; multiply for reality.

### Milestone 0 — Planning frozen (this turn)

Files: `swift-sdk/planning/v1.1/01–10.md`, `swift-sdk/docs/diagrams/{target-dependency,job-fsm}.dot`.

Already done by the bootstrap. Closes when this synthesis is reviewed.

### Milestone 1 — v1.0 wire alignment (the foundation)

**This is the largest milestone.** Split into ten sub-PRs so reviewers
can land them incrementally. Each maps to a spec section.

| PR  | Scope                                                                                                                                                                       | Files                                                                                                                                                          | Spec §                              | Approx. lines             |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------- | ------------------------- |
| 1A  | New `Envelope` (8 fields per §5.1) + manual `Codable` for `type` discriminator. Drop `timestamp`, `source`, `target`, `stream_id`, `subscription_id`, span IDs, `correlation_id`, `causation_id`, `idempotency_key` (moves to payload), `priority`, `extensions`. | `Sources/ARCPCore/Envelope/`                                                                                                                                   | §5.1                                | ~400 deleted, ~150 added  |
| 1B  | `Message` enum + v1.0 message types: `session.hello/welcome/bye/error`, `job.submit/accepted/event/result/error/cancel`.                                                    | `Sources/ARCPCore/Messages/`                                                                                                                                   | §6.1–§7.4, §8.1                     | ~600                      |
| 1C  | 2-step session handshake (hello/welcome) + `ResumeToken` rotation in `ARCPRuntime`. Replaces 4-step challenge handshake.                                                    | `Sources/ARCPClient/`, `Sources/ARCPRuntime/`                                                                                                                  | §6.1, §6.2, §6.3                    | ~800                      |
| 1D  | `event_seq` session-scoped monotonic counter; replay keyed on `last_event_seq` (not message id). In-memory ring buffer default; `RESUME_WINDOW_EXPIRED` error.              | `Sources/ARCPCore/Messages/`, `Sources/ARCPRuntime/EventSeq.swift`, `Sources/ARCPRuntime/ResumeBuffer.swift`                                                   | §5.1, §6.3, §8.3                    | ~500                      |
| 1E  | Unified `job.event` envelope; `JobEventBody` enum for 8 v1.0 kinds (`log`, `thought`, `tool_call`, `tool_result`, `status`, `metric`, `artifact_ref`, `delegate`).            | `Sources/ARCPCore/Messages/JobEvent.swift`                                                                                                                     | §8.1, §8.2                          | ~400                      |
| 1F  | Lease model rewrite: immutable `Lease` value type, `Capability` enum with `xVendor(String)`, `Pattern` glob compiler (anchored `*`/`**`), `LeaseEvaluator.authorize`.        | `Sources/ARCPCore/Lease/`, `Sources/ARCPRuntime/LeaseEvaluator.swift`                                                                                          | §9.1–§9.4, §14                      | ~700                      |
| 1G  | Error code overhaul: 12-case v1.0 `ARCPError`. Drop gRPC-style codes from `Errors/ErrorCode.swift`. Computed `retryable`.                                                    | `Sources/ARCPCore/Errors/`                                                                                                                                     | §12                                 | ~200 deleted, ~250 added  |
| 1H  | Delegation (event-kind, not envelope-type): `delegate` body, parent-trace inheritance, `LEASE_SUBSET_VIOLATION` on subset failure.                                          | `Sources/ARCPCore/Messages/`, `Sources/ARCPRuntime/Delegation.swift`                                                                                           | §10                                 | ~350                      |
| 1I  | Strip dead surfaces: HITL (`Human.swift`, `Permissions.swift`), `Artifacts.swift`, `Streaming.swift`, `Subscriptions.swift` (current shape), `Control.swift`, lease envelopes; move JWT auth to opt-in `ARCPAuthJWT` target. Drop SQLite from default. | Delete `Sources/ARCP/Messages/{Human,Permissions,Artifacts,Streaming,Subscriptions}.swift`; move `Auth/JWTAuth.swift` to new opt-in target; default deps trim. | (out of scope per spec)             | ~2000 deleted             |
| 1J  | Target split per [`04-architecture.md`](04-architecture.md) §1: rewrite `Package.swift`, move files into `Sources/ARCP{Core,Client,Runtime}/`. Add `ARCPWebSocketClient` shell (impl in Milestone 4). | `Package.swift`, full source tree move                                                                                                                         | n/a                                 | mechanical                |

Definition of done for Milestone 1: a `submit-and-stream` example
compiles and round-trips through `MemoryTransport` against v1.0
spec-shaped envelopes, with no v1.1 features.

### Milestone 2 — Feature negotiation foundation

Required before any v1.1 feature lands.

| PR  | Scope                                                                                                                                                                                                                            | Files                                                                                                              | Spec §              |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ | ------------------- |
| 2A  | `Feature` enum (9 cases) with raw-value mapping for `cost.budget`/`agent_versions`. `Sendable`, `Hashable`, `CaseIterable`, `Codable`.                                                                                            | `Sources/ARCPCore/Feature.swift`                                                                                   | §6.2                |
| 2B  | `Capabilities` struct with `encodings: [String]` + `features: Set<Feature>` + `agents: [AgentRecord]` (flat-or-rich union). Hello/welcome intersection logic. Client-side feature-gate preconditions on every v1.1 client method. | `Sources/ARCPCore/Messages/Session.swift` (hello/welcome), `Sources/ARCPClient/ARCPClient.swift` (precondition).   | §6.2                |

### Milestone 3 — v1.1 features (one PR each, mostly independent)

After Milestone 2, these can land in any order. Each PR is small
(≤ ~500 lines incl. tests) because the foundation is now correct.

| PR  | Feature flag         | Scope                                                                                                                                          | Spec §           | H-risk?                   |
| --- | -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- | ------------------------- |
| 3A  | `heartbeat`          | `session.ping`/`session.pong` envelopes, `ContinuousClock`-driven ping timer, `HEARTBEAT_LOST` after 2 silent intervals, `heartbeat_interval_sec` in welcome. | §6.4             | no                        |
| 3B  | `ack`                | `session.ack`; client `ack(seq:)` + `autoAck` debounce; runtime ack cursor + `back_pressure` status event.                                      | §6.5             | no                        |
| 3C  | `list_jobs`          | `session.list_jobs`/`session.jobs`; filter (status/agent/created_after) + cursor; same-principal auth policy hook.                              | §6.6             | no                        |
| 3D  | `subscribe`          | `job.subscribe`/`job.subscribed`/`job.unsubscribe`; `JobSubscription` struct (no `cancel()`); `AsyncThrowingStream.onTermination` frees runtime subscriber. | §7.6             | **H** ([`02-current-audit.md`](02-current-audit.md) §3) |
| 3E  | `progress`           | `JobEventBody.progress(current:total:units:message:)`; `JobContext.progress(...)` helper.                                                       | §8.2.1           | no                        |
| 3F  | `result_chunk`       | `JobEventBody.resultChunk`; `ResultChunkData = .utf8(String) | .base64(Data)` union; `ResultChunkWriter` actor; client-side `Data` accumulator with `reserveCapacity`; 1 MiB chunk cap, 256 MiB total cap; `INTERNAL_ERROR` on exceed. | §8.4, §14        | **H** ([`02-current-audit.md`](02-current-audit.md) §3) |
| 3G  | `lease_expires_at`   | `LeaseConstraints { expiresAt }` on submit/accepted; `ContinuousClock`-driven lease-expiry sweep in `JobActor`; `LEASE_EXPIRED` on validate.    | §9.5, §14        | M (clock-skew test)       |
| 3H  | `cost.budget`        | `Budget` struct (`[Currency: Decimal]`); `cost.*` metric decrement; `BUDGET_EXHAUSTED` on counter ≤ 0; budgeted lease-subsetting; debounced `cost.budget.remaining` emission. | §9.6, §9.4      | M (Decimal arithmetic, cross-actor snapshot) |
| 3I  | `agent_versions`     | `parseAgentRef("name@version")`; runtime `registerAgentVersion`/`setDefaultAgentVersion`; rich `agents` shape in welcome; `AGENT_VERSION_NOT_AVAILABLE` error. | §7.5, §12        | no                        |
| 3J  | three new error codes | Already partially added by 3F/3G/3I; this PR is the consolidated error-table refactor (15-case `ARCPError`), `retryable = false` for all three, structured-context cases. | §12              | no                        |

Recommended landing order **inside Milestone 3**: 3A → 3B → 3E → 3I →
3J → 3C → 3G → 3H → 3D → 3F. The first five are cheap and unblock
example PRs; the last two are H-risk and want the test infrastructure
landed first.

### Milestone 4 — Middleware adapters + WS transport

| PR  | Target                  | Scope                                                                                                                                                        | Depends on                                                  |
| --- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------- |
| 4A  | `ARCPWebSocketClient`   | `URLSessionWebSocketTask`-backed client transport. Linux fallback if Phase 3 verify-before-commit fails (`websocket-kit` as escape hatch).                  | M1                                                          |
| 4B  | `ARCPVapor`             | Vapor 4.x WS upgrade attach point; Host-header allowlist; `onClose` → session-close wiring (per [`05-middleware.md`](05-middleware.md) §1 risk).            | M1 + 4A                                                     |
| 4C  | `ARCPHummingbird`       | Hummingbird 2.x via `hummingbird-websocket`. Router-group attachment.                                                                                        | M1                                                          |
| 4D  | `ARCPNIO`               | Raw SwiftNIO. `NIOAsyncChannel`-based. Framework-free seam.                                                                                                  | M1                                                          |
| 4E  | `ARCPOTel`              | `swift-distributed-tracing` + `slashmo/swift-otel`. Span per envelope; v1.1 span attributes (`arcp.lease.expires_at`, `arcp.budget.remaining`). `traceparent` extracted from envelope `extensions["x-vendor.opentelemetry.tracecontext"]` per the TS reference (contradiction §4 above). | M3 (needs `lease_expires_at` + `cost.budget` body shapes)   |
| 4F  | `ARCPStoreSQLite`       | Opt-in SQLite-backed event log + resume buffer; wires existing [`Store/EventLog.swift`](../../Sources/ARCP/Store/EventLog.swift) salvaged from current code. | M1                                                          |

### Milestone 5 — Examples (22)

Per [`06-examples.md`](06-examples.md) §1. Each example is one PR
(or grouped 2–3 if trivially short). Internal `ExampleHarness`
library target lands first as a separate PR.

| PR  | Bundle                                                                                            | Count |
| --- | ------------------------------------------------------------------------------------------------- | ----- |
| 5A  | `ExampleHarness` library target.                                                                   | (lib) |
| 5B  | v1.0 core 9: `SubmitAndStream`, `Delegate`, `Resume`, `IdempotentRetry`, `LeaseViolation`, `Cancel`, `Stdio`, `VendorExtensions`, `CustomAuth`. | 9     |
| 5C  | v1.1 features 9: `Heartbeat`, `AckBackpressure`, `ListJobs`, `Subscribe`, `AgentVersions`, `LeaseExpiresAt`, `CostBudget`, `Progress`, `ResultChunk`. | 9     |
| 5D  | host integrations 4: `OtelTracing`, `Vapor`, `Hummingbird`, `NIO`.                                 | 4     |

### Milestone 6 — Docs + CONFORMANCE + CHANGELOG

| PR  | Scope                                                                                                                                                                                                                                                                                                | Files                                                                                                                                  |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| 6A  | `docs/` tree per [`08-docs-readme.md`](08-docs-readme.md) §1 (frontmatter on every file).                                                                                                                                                                                                              | `docs/{index,getting-started}.md` + `concepts/`, `guides/`, `reference/` subtrees.                                                     |
| 6B  | DocC catalogs per target (`Sources/<Target>/Documentation.docc/`) + symbol docs on public surface. CI step `swift package generate-documentation --target ARCP` passes.                                                                                                                              | `Sources/ARCPCore/Documentation.docc/`, plus same for `ARCPClient`/`ARCPRuntime`/`ARCP`/middleware.                                    |
| 6C  | `README.md` rewrite — 10 sections per [`08-docs-readme.md`](08-docs-readme.md) §3; remove ✅ emoji; SwiftPM snippet; quickstart linked to `Samples/SubmitAndStream/`.                                                                                                                                  | `README.md`                                                                                                                            |
| 6D  | `CONFORMANCE.md` mirroring TS structure; status from test names (Phase 7 conformance harness emits a report).                                                                                                                                                                                        | `CONFORMANCE.md`                                                                                                                       |
| 6E  | `CHANGELOG.md` v1.1.0 entry per Keep a Changelog 1.1; "Added"/"Changed"/"Removed"/"Security" populated; cite audit headline (wire surface rebuilt from `draft-arcp-01.md` lineage).                                                                                                                  | `CHANGELOG.md`                                                                                                                         |

### Milestone 7 — Test gates & CI matrix

| PR  | Scope                                                                                                                                                                                                                                                                                          |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 7A  | Test stack migration: new `swift-testing` cases per [`07-tests.md`](07-tests.md) §1; `TestClock` injection on `ARCPRuntime.Configuration`/`ARCPClient.Configuration`.                                                                                                                            |
| 7B  | Five-layer test plan rollout (envelopes ~30, bodies ~40, state machines ~25, integration ~20, conformance harness).                                                                                                                                                                            |
| 7C  | Coverage gate: 87% lines + `functions ≥ 90%`. `llvm-cov export --ignore-filename-regex` exclusions.                                                                                                                                                                                             |
| 7D  | CI matrix: macOS (current Xcode), Linux Swift 6.x Docker, iOS Simulator (`xcodebuild test` for `ARCPCore` + `ARCPClient` only). Lint gates: `swift-format`, `swiftlint` (banned `DispatchQueue`/`@unchecked Sendable`/`Task.sleep` in tests).                                                    |

### Milestone 8 — Diagrams

| PR  | Scope                                                                                                                                                                                          |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 8A  | Six `.dot` sources under `docs/diagrams/` per [`09-diagrams.md`](09-diagrams.md) §1, plus rendered SVGs. The two skeletons already exist; finish the four remaining. Update `target-dependency.dot` per contradiction §9 above. |

## 4. Risk register

Concrete, Swift-specific. Generic risks rejected.

| Risk                                                                                                                                                                                                                                                                                | Severity | Mitigation                                                                                                                                                                                                                                                            |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`AsyncThrowingStream` lifecycle on subscribe.** A subscriber that drops its stream mid-flight leaks a runtime-side subscriber entry. ([`02-current-audit.md`](02-current-audit.md) §3, [`07-tests.md`](07-tests.md) §2 layer 4)                                                                                                                  | **H**    | `.onTermination` closure in `JobSubscription.events()` sends `job.unsubscribe` and frees the runtime entry. Test: subscribe, consume 5 events, drop the stream, `Task.yield()` × N, assert runtime subscriber count == 0.                                              |
| **`result_chunk` accumulator memory shape.** Naïve `String += chunk` is O(n²); a 256 MiB result would OOM. ([`02-current-audit.md`](02-current-audit.md) §3)                                                                                                                                                                                          | **H**    | `Data` accumulator with `reserveCapacity(byte_size)` from the `job.result.payload.result_size` field; chunks decoded into the accumulator in order. Spec §14 caps (1 MiB/chunk, 256 MiB total) enforced server-side. Test: 5 MiB chunked stream + mid-stream cancel.   |
| **`URLSessionWebSocketTask` on Linux pre-Swift-6.x.** `swift-corelibs-foundation` historically lagged Apple's URLSession; TLS / proxy / redirect behavior differs ([`03-libraries.md`](03-libraries.md), audit §2.2).                                                                                                                                | M        | `ARCPWebSocketClient` is its own SwiftPM target so the dep swap is one line. Phase 3 lists `verify before commit` action items for Swift 6.1 Linux TLS/redirect/proxy CONNECT.                                                                                          |
| **`Date` is wall-clock, not monotonic.** Spec §14 requires monotonic clock for `expires_at` (NTP-disciplined). [`02-current-audit.md`](02-current-audit.md) §3 flags the existing `LeaseManager.swift:49,83` using `Date(timeIntervalSinceNow:)` as wrong.                                                                                          | M        | `ContinuousClock` for elapsed-time decisions everywhere; `Date` only for serializing `expires_at` over the wire. `TestClock` enables wall-clock-jump tests. Test: jump `Date` backward 60s, lease still expires correctly per `ContinuousClock`.                       |
| **Cross-currency `Decimal` arithmetic.** A `Budget` with `USD:5.00` decremented by a `EUR` metric is undefined; spec §9.6 tracks currencies independently. [`01-spec-delta.md`](01-spec-delta.md) §4 flags this.                                                                                                                                    | M        | `Budget.decrement(currency:by:)` accepts a typed `Currency`; mismatched currency is a no-op for the requested decrement and a `precondition` in debug. Cross-currency arithmetic forbidden at the type level.                                                          |
| **`ARCPOTel` traceparent source divergence.** [`05-middleware.md`](05-middleware.md) extracts traceparent from envelope extensions, not upgrade headers; this is the TS reference shape but is non-obvious.                                                                                                                                          | L        | Documented in `ARCPOTel` README + DocC overview; one DocC `<discussion>` paragraph cites the TS file line. Test: an envelope with `extensions["x-vendor.opentelemetry.tracecontext"]` set produces a span; one without, no span.                                       |
| **JWT auth dep drop breaks existing CLI users.** Current `Package.swift` ships `jwt-kit` 5.1..<5.3 (audit §2.1). v1.0/v1.1 use bearer tokens; JWT becomes opt-in `ARCPAuthJWT`. Pre-release callers may break.                                                                                                                                     | L        | Per audit §0 the SDK has no released consumers. `CHANGELOG.md` Milestone 6E records the breaking change. JWT lands as a single opt-in target consumers can re-add.                                                                                                    |
| **22-example smoke set wall time.** 22 examples × ~10s each ≈ 4 min serial. CI budget contention.                                                                                                                                                                                                                                                 | L        | `swift run` invocations parallelized in CI via `xargs -P 4`. Per-example `timeout 60` guard per [`06-examples.md`](06-examples.md) CI runner.                                                                                                                          |
| **DocC docs build memory on Linux CI.** `swift package generate-documentation` historically OOMs on small CI runners.                                                                                                                                                                                                                              | L        | Generate docs only on the macOS CI matrix row; Linux runs `swift build --target ARCP` to confirm the catalog markdown parses but skips full DocC.                                                                                                                     |

## 5. Non-goals

Carry forward from spec §"Not in v1.1 (deferred)" + [`01-spec-delta.md`](01-spec-delta.md) §5:

- **Job pause / unpause.** Deferred by spec. No example, no API, no DocC entry.
- **Job priority and scheduling hints.** Same.
- **Federation across runtimes.** Same.
- **Streaming-token surface for LLM outputs.** Same.

Carry forward from this SDK's deletions ([`02-current-audit.md`](02-current-audit.md) §4 throwaway list):

- **Permission-challenge / HITL / artifact / lease-revoke envelopes.** Out of scope of ARCP v1.0/v1.1; the host application's concern. The existing samples (`Samples/Permission-Challenge`, `Samples/Human-Input`, etc.) are deleted, not migrated.
- **`stream.*` envelopes.** Replaced by `job.event { kind: ... }`.
- **gRPC-style `ErrorCode` enum.** Replaced wholesale.

Phase 4 + 6 + 8 owners MUST reject any PR that re-introduces these.

## 6. Open questions

These need a human decision before kickoff. Each is one sentence.

1. **Backward-compat policy for SDK consumers.** Audit §0 finds no released consumers — confirm before the API breaks land. If wrong, Milestone 1 needs a v0 → v1.1 migration shim and a longer deprecation path.
2. **Linux WebSocket client choice.** `URLSessionWebSocketTask` on Swift 6.1 Linux: works for TLS / proxy CONNECT / redirect? Need a one-day spike against [`03-libraries.md`](03-libraries.md) verify-before-commit items. Fallback: `websocket-kit` (kept on the dep roster as escape hatch).
3. **JWT auth shipping**: ship `ARCPAuthJWT` opt-in target in v1.1.0, or drop entirely and let consumers add it later? Recommend ship as opt-in.
4. **Hummingbird major version**. `hummingbird-2` (current) vs the upcoming 3.x. [`05-middleware.md`](05-middleware.md) targets 2.x; confirm before pinning.
5. **iOS as a CI matrix row from day 1.** [`07-tests.md`](07-tests.md) §4 includes iOS Simulator; if the CI cost is unacceptable, defer until after Milestone 3.
6. **TS docs frontmatter backfill** (contradiction §6 above). Cross-repo issue or one-PR addition by the TS SDK owners?
7. **`@arcp/middleware-otel` traceparent source documentation.** Open a TS-side issue confirming envelope-extensions is the intended canonical source (contradiction §4); the wire reference is the TS implementation per [`05-middleware.md`](05-middleware.md) §2.
8. **`ARCPStoreSQLite` API shape.** [`02-current-audit.md`](02-current-audit.md) §4 says salvage [`Store/EventLog.swift`](../../Sources/ARCP/Store/EventLog.swift). Confirm the resume buffer protocol seam (`ResumeBuffer`) is the only contract the SQLite store needs to honor — or do we also persist idempotency keys? [`01-spec-delta.md`](01-spec-delta.md) suggests idempotency persistence is a deployer concern, but the runtime needs to opt into a persistent store.

## 7. Definition of done for v1.1.0 release

- All ten Milestone 1 PRs merged. v1.0 wire surface alone passes the
  `submit-and-stream` example through `MemoryTransport` and (per
  Milestone 4A) `WebSocketTransport`.
- Milestones 2 + 3 merged. All nine v1.1 features negotiate; each
  has a dedicated example.
- `CONFORMANCE.md` mirrors `typescript-sdk/CONFORMANCE.md` row-for-row
  for §4–§15 with all `Implemented` cells citing `file:line`.
- 22 examples in `Samples/` run via `swift run <Name>` to exit code 0
  in CI.
- Five-command gate (current [`README.md:68-73`](../../README.md#L68))
  passes on macOS + Linux. iOS Simulator gate passes on `ARCPCore` +
  `ARCPClient`.
- Coverage ≥ 87% lines / ≥ 90% functions.
- Six `docs/diagrams/*.svg` rendered.
- `swift package generate-documentation --target ARCP` succeeds.
- README + CHANGELOG updated.

---

End of synthesis. Implementation starts with Milestone 1 PR 1A
([`Sources/ARCPCore/Envelope/`](../../Sources/ARCP/Envelope/) rewrite).
