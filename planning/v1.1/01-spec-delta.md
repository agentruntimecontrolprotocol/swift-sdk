# 01 — ARCP v1.1 spec delta

**Source:** [`../spec/docs/draft-arcp-02.1.md`](../../../spec/docs/draft-arcp-02.1.md)
(v1.1), additive over [`../spec/docs/draft-arcp-02.md`](../../../spec/docs/draft-arcp-02.md)
(v1.0). Envelope `arcp` field stays `"1"`.

## 1. Additions table

Every row cites the v1.1 spec section, names the on-wire artifact, and
classifies the change for a Swift implementation that today targets a
**different lineage** (the swift-sdk is on `RFC-0001-v2.md` /
[`draft-arcp-01.md`](../../../spec/docs/draft-arcp-01.md), not
`draft-arcp-02.md`). "Additive vs v1.0" is the cheap question; the
expensive question is "additive vs the current Swift code," covered in
[`02-current-audit.md`](02-current-audit.md).

| §       | Feature flag        | Artifact                                                                           | Conformance | Additive vs v1.0 | Additive vs current Swift                                                                |
| ------- | ------------------- | ---------------------------------------------------------------------------------- | ----------- | ---------------- | ---------------------------------------------------------------------------------------- |
| §6.2    | _(negotiation)_     | `capabilities.features: [String]` on `session.hello` + `session.welcome`           | MUST        | additive         | additive (current code has no feature-intersection model — see audit §2.3)               |
| §6.2    | `agent_versions`    | rich `capabilities.agents: [{name, versions, default?}]` shape in `session.welcome` | MAY         | additive         | additive (current code: no agent inventory at all on welcome)                            |
| §6.4    | `heartbeat`         | `session.ping` / `session.pong`, `welcome.heartbeat_interval_sec`                  | SHOULD      | additive         | partial — Swift already has a "ping" surface, but not §6.4 envelope shape (audit §2.4)   |
| §6.5    | `ack`               | `session.ack { last_processed_seq }`                                               | MAY         | additive         | new — no analogue                                                                        |
| §6.6    | `list_jobs`         | `session.list_jobs` / `session.jobs` w/ filter + cursor                            | MAY         | additive         | new — no analogue (current SDK has subscriptions but no read-only inventory)             |
| §7.1    | `lease_expires_at`  | `job.submit.payload.lease_constraints.expires_at`                                  | OPTIONAL    | additive         | partial — current SDK has lease lifecycle + revocation, but no `expires_at` constraint   |
| §7.1    | `cost.budget`       | `job.accepted.payload.budget`                                                      | OPTIONAL    | additive         | new — no budget concept in current SDK                                                   |
| §7.5    | `agent_versions`    | `agent ::= name | name "@" version` grammar                                        | MAY         | additive         | new — current SDK's "agent" surface is the tool-invocation model (audit §2.2)            |
| §7.6    | `subscribe`         | `job.subscribe` / `job.subscribed` / `job.unsubscribe`                             | MAY         | additive         | partial — Swift has `SubscriptionManager`, but topic/filter shape, not §7.6 (audit §2.5) |
| §8.2.1  | `progress`          | event `kind: "progress"` with `{current, total?, units?, message?}`                | SHOULD      | additive         | partial — Swift has `kind: "progress"` in streams but body shape differs                 |
| §8.4    | `result_chunk`      | event `kind: "result_chunk"` + `job.result.payload.result_id`                      | OPTIONAL    | additive         | new — current SDK uses inline-base64 artifacts, not chunked result streams               |
| §9.4    | _(subsetting)_      | budget + `expires_at` subsetting on delegation                                     | MUST        | additive         | new — Swift has no delegation today (audit §2.6)                                         |
| §9.5    | `lease_expires_at`  | runtime evaluates `expires_at` per op; `LEASE_EXPIRED` on miss                     | MUST        | additive         | partial — `LeaseManager` tracks expiry sweeps but not §9.5 semantics                     |
| §9.6    | `cost.budget`       | per-currency counters, `cost.*` metric decrements, `BUDGET_EXHAUSTED`              | MUST        | additive         | new                                                                                      |
| §11     | _(tracing)_         | recommend `arcp.lease.expires_at`, `arcp.budget.remaining` span attrs              | SHOULD      | additive         | new — current SDK ships no tracing seam                                                  |
| §12     | _(errors)_          | `LEASE_EXPIRED`, `BUDGET_EXHAUSTED`, `AGENT_VERSION_NOT_AVAILABLE`                 | MUST        | additive         | new                                                                                      |

**Read this table as:** v1.1 is additive over v1.0, but the Swift SDK
is not on v1.0 — it is on draft-arcp-01. The migration cost is dominated
by reaching v1.0 parity (covered in audit Phase 2), not by adding the
nine v1.1 feature flags on top.

## 2. Three new error codes (§12)

The canonical v1.1 set is 15 codes (12 v1.0 + 3 new). All three new
codes MUST be returned with `retryable: false`.

| Code                          | When                                                                                                 | Source of the failure                                                                                                          |
| ----------------------------- | ---------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `LEASE_EXPIRED`               | An operation is attempted at or after `lease_constraints.expires_at`; or the runtime times out a running job whose lease has elapsed | Runtime-side clock check during `validateLeaseOp`; periodic sweep for already-running jobs                                     |
| `BUDGET_EXHAUSTED`            | Any `cost.budget` per-currency counter reaches ≤ 0 before authorizing the next op                    | Runtime-side counter decrement on agent-reported `metric { name: cost.*, unit: <ccy> }` events; checked on next lease-bound op |
| `AGENT_VERSION_NOT_AVAILABLE` | `job.submit.payload.agent = "name@version"` where `name` exists but `version` does not               | Synchronous rejection at submit time, surfaced as `session.error` per §13.7                                                    |

Swift surface implications (no code here — see
[`04-architecture.md`](04-architecture.md)):

- `ARCPError` becomes a closed `enum` with one case per code. `case
  budgetExhausted(currency: String, attempted: Decimal)`,
  `case leaseExpired(at: Date)`, `case agentVersionNotAvailable(name:
  String, version: String, available: [String])` carry the structured
  context the spec requires for client-side handling.
- `retryable` is a computed property on the enum (`false` for these
  three), not a stored field that can drift from the case.
- `Decimal` (not `Double`) for budget amounts — fractional currency is
  the entire point of the surface, and `Double` corrupts cents by
  rounding. Spec amount-string grammar (`USD:5.00`) is decimal-exact.

## 3. Capability negotiation (§6.2)

v1.0 had a `capabilities` object with `encodings` and `agents`. v1.1
adds `features: [String]` and a richer `agents` shape. The effective
feature set is the intersection of hello-features and welcome-features;
either peer MUST NOT use a feature outside the intersection.

The contract is symmetric:

- A v1.1 client connecting to a v1.0 runtime sees no `features`
  array (or an empty one). It MUST degrade to v1.0 semantics — no
  ack, no list_jobs, no subscribe, no progress, no result_chunk, no
  lease_constraints, no `name@version`. Mistake-shaped surface: a
  client that calls `client.ack(seq)` against a v1.0 server MUST throw
  `INVALID_REQUEST` locally rather than emit a wire message the
  runtime will reject.
- A v1.0 client connecting to a v1.1 runtime sends no `features`.
  The runtime MUST advertise its full feature set anyway (clients
  ignore unknown fields per §5.1) and MUST NOT use v1.1 wire types
  toward this peer. In particular, `session.welcome.payload.agents`
  uses the flat `[String]` shape for v1.0 clients OR the rich shape
  unconditionally (v1.0 client ignores the extra structure per
  envelope passthrough rule). The TS SDK chose the unconditional-rich
  approach (`packages/runtime/src/server.ts:makeNegotiatedCapabilities`);
  Swift will mirror this.

Two Swift idioms enforce the negotiation:

1. The negotiated feature set is held by the session actor as a
   `Set<Feature>` value. `Feature` is a closed enum with raw value
   `String`, so the wire form is a string list but the in-process form
   is exhaustive-switchable. Unknown wire features round-trip through
   the welcome but do not enter `Set<Feature>`; this is the intersection.
2. Feature-gated public methods (`subscribe`, `listJobs`, `ack`,
   `submit(..., expiresAt:)`, `submit(..., budget:)`) precondition on
   the negotiated set. The check happens before any envelope is built.

The `Feature` enum's canonical set (mirroring TS
`packages/core/src/version.ts:V1_1_FEATURES`):

```
heartbeat, ack, list_jobs, subscribe, lease_expires_at,
cost.budget, progress, result_chunk, agent_versions
```

Wire form is the dot-namespaced string (`cost.budget`); Swift form is
`.costBudget` with a custom `RawRepresentable` mapping. See architecture
plan for the rationale (Swift enum case names cannot contain `.`).

## 4. Other items worth flagging up front

These are mentioned inline in the additions table but recur across
later phases:

- **§5.1 passthrough**: v1.0 already required ignoring unknown
  top-level envelope fields. Swift's `JSONDecoder` does this by default;
  there is nothing to add, but the test plan
  ([`07-tests.md`](07-tests.md)) MUST include an explicit "v1.0 client
  decodes a v1.1 envelope" round-trip test, because the rule is silent
  but load-bearing for forward compatibility.
- **§7.3 lifecycle**: v1.1 introduces no new terminal states.
  `LEASE_EXPIRED` and `BUDGET_EXHAUSTED` both terminate with
  `final_status: "error"`. The Swift `JobState` enum does not change.
- **§7.6 vs §6.3 (subscribe vs resume)**: The spec spells out the
  table in §7.7. Subscribers MUST NOT carry cancel authority. The Swift
  type model must make this impossible at the type level: a `Job`
  obtained via `client.subscribe(jobID:)` returns a `JobSubscription`,
  not a `Job` — only the latter exposes `cancel()`.
- **§8.4 chunk encoding**: `encoding ∈ {"utf8", "base64"}`. Swift
  represents `Data` for binary and `String` for text. The body model
  should be `enum ResultChunkData { case utf8(String); case
  base64(Data) }` so a misuse like base64-encoding a string at the
  type level is impossible.
- **§9.6 currency**: `currency ::= "USD" | "EUR" | "credits" | <runtime-defined>`.
  The protocol does NOT close the currency set, so `Currency` cannot be a
  closed Swift enum without breaking forward-compat with runtime-defined
  currencies. It is a `String` wrapper with three named constants and
  validation against the `[A-Za-z][A-Za-z0-9_-]*` shape implied by the
  grammar. Amounts are `Decimal`; mixing currencies in arithmetic is
  a programmer error and `Budget` panics in debug, returns the LHS in
  release (`Decimal` arithmetic across currencies is meaningless).
- **§14 security — `expires_at` clock**: "monotonic, NTP-disciplined
  clock." Swift's `Date` is NOT monotonic (it tracks wall time and
  jumps backward on NTP adjustment). The runtime MUST use
  `ContinuousClock`/`SuspendingClock` for elapsed-time decisions and
  `Date` only for serializing the lease constraint. The architecture
  plan ([`04-architecture.md`](04-architecture.md)) calls this out.
- **§14 chunk-size cap**: "individual chunk size (e.g., 1 MB) and
  total streamed result size." Swift defaults: 1 MiB per chunk, 256 MiB
  total. Configurable on the runtime; `INTERNAL_ERROR` on exceed.

## 5. Non-goals for v1.1 (carry forward to synthesis)

The spec defers four items explicitly (Abstract):

- Job pause/unpause.
- Job priority and scheduling hints.
- Federation across runtimes.
- Streaming-token surface for LLM outputs.

Swift planning MUST NOT preempt these. If a phase proposes them, reject.
