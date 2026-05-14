# 07 — Test strategy (ARCP v1.1 Swift SDK)

Floor: **87% lines** (Swift `llvm-cov` lacks gcov-shaped branch counts —
substitute is `functions ≥ 90%`; rationale in §5). The plan applies on
top of the v1.0 wire alignment described in
[`02-current-audit.md`](02-current-audit.md); v1.1 tests assume the v1.0
envelopes already round-trip.

Required reading order: [`BOOTSTRAP.md`](../../BOOTSTRAP.md) §"Phase 7",
[`01-spec-delta.md`](01-spec-delta.md),
[`02-current-audit.md`](02-current-audit.md) §3 (H-risk),
[`../../../typescript-sdk/CONFORMANCE.md`](../../../typescript-sdk/CONFORMANCE.md)
§4–§15 (the table the Swift conformance report mirrors row-for-row).

---

## 1. Test stack

| Concern                  | Pick                                                                       | Why                                                                                                                                                                                                                                                                |
| ------------------------ | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| New tests                | `swift-testing` (Swift 6.0+) — `@Test`, `@Suite`, `#expect`, `#require`    | Free parameterized cases (`@Test(arguments:)`), structured-concurrency aware (each `@Test` runs in its own `Task` with cancellation honoured), `#expect` macros surface the failing sub-expression. Avoids `XCTest`'s expectation/fulfill/wait boilerplate.        |
| Compat                   | Existing `XCTest` cases stay until rewritten module-by-module              | `Tests/ARCPTests/{EnvelopeTests,ErrorsTests,EventLogTests,ExtensionsTests,IdsTests}.swift` and the `Integration/` subdir survive the migration window. **Policy: no new test starts in `XCTest`.** Rewritten cases land in `swift-testing` form.                  |
| Snapshots                | `pointfreeco/swift-snapshot-testing`                                       | Earn-its-keep test: **wire-format envelope golden parity.** One concrete case: Swift's encoded `session.welcome` envelope (sorted keys, no extra whitespace) byte-equals a golden captured from the TS SDK at `typescript-sdk/packages/core/src/messages/session.ts`. Cross-language parity, not Swift-internal regression. |
| Async time travel        | `Clock` protocol — `ContinuousClock` in production, `TestClock` in tests   | The SDK accepts an injectable `any Clock<Duration>` on `ARCPRuntime.Configuration` and `ARCPClient.Configuration`. Heartbeat interval (§6.4), ack debounce (§6.5), lease `expires_at` (§9.5), and budget metric ticks (§9.6) all read from it. No `Task.sleep`-based races; tests advance time with `clock.advance(by: .seconds(N))`. |
| Async assertions         | `swift-testing`'s `confirmation { … }`                                     | Replaces `XCTestExpectation`. `confirmation(expectedCount: N) { confirm in … }` proves an event fired exactly N times within scope; failures point at the `#expect` site, not a generic timeout.                                                                  |

No `swift-asynchronous-testing` package — `swift-testing` + the `Clock`
seam covers what that package adds.

---

## 2. Layered test plan

Each suite name is the literal `@Suite("…")` string. Counts are upper
bounds on **distinct cases** (parameterized rows count once).

### Layer 1 — Envelope unit tests (≈30 cases)

**Suite:** `@Suite("Envelope wire format")`.
**Covers:** `Sources/ARCPCore/Envelope/*.swift`.

Every v1.0+v1.1 envelope round-trips: encode the Swift struct, decode
the bytes, `#expect(decoded == original)`. The wire spec ([§5.1](../../../spec/docs/draft-arcp-02.1.md))
is the contract; these tests pin it. Cases:

- v1.0 envelopes: `session.hello`, `session.welcome`, `session.error`,
  `session.bye`, `job.submit`, `job.accepted`, `job.event`, `job.result`,
  `job.error`, `job.cancel` (10).
- v1.1 envelopes: `session.ping`, `session.pong`, `session.ack`,
  `session.list_jobs`, `session.jobs`, `job.subscribe`,
  `job.subscribed`, `job.unsubscribe` (8).
- §5.1 invariants: `arcp == "1"` required (decode of `"2"` throws);
  `id` must parse as ULID-26 or UUID-36 (`Sources/ARCPCore/Ids/Ulid.swift`);
  `event_seq` required on `job.event`/`job.result`/`job.error` and
  monotonic per session; `trace_id` matches W3C 32-hex when present
  (current validator `Sources/ARCP/Trace/TraceContext.swift`) (6).
- §5.1 unknown-field passthrough: decode a v1.1 envelope with a future
  field, re-encode, future field is preserved (the spec rule is "ignore
  unknown" — Swift's `JSONDecoder` honours by default; the test exists
  because the audit flagged it as silent-but-load-bearing) (2).
- Cross-language parity (snapshot): `session.welcome` and `job.accepted`
  byte-match TS-emitted goldens checked into
  `Tests/ARCPCoreTests/__Snapshots__/` (4).

### Layer 2 — Message body tests (≈40 cases)

**Suite:** `@Suite("Message bodies")`.
**Covers:** `Sources/ARCPCore/Messages/*.swift`.

Each v1.1 event kind body parses to its typed model and rejects malformed
input. Each capabilities shape decodes both ways. Each error code
preserves its structured context.

- v1.0 event kinds (one happy + one negative case each): `log`,
  `thought`, `tool_call`, `tool_result`, `status`, `metric`,
  `artifact_ref`, `delegate` (16). Negatives target the discriminator:
  `tool_call` without `call_id` throws (§8.2 cross-link rule).
- v1.1 event kinds: `progress` (`{current, total?, units?, message?}`,
  spec §8.2.1), `result_chunk` (with `encoding ∈ {"utf8","base64"}`,
  spec §8.4). The `encoding` discriminator is enforced by the
  `ResultChunkData` enum (`.utf8(String)` vs `.base64(Data)`, per
  [`01-spec-delta.md`](01-spec-delta.md) §4); a base64-encoded value
  decoded as `.utf8` throws (4).
- Capabilities (§6.2):
  - flat agents (`[String]`) decodes (v1.0 client view).
  - rich agents (`[{name, versions, default?}]`) decodes (v1.1 view).
  - mixed-shape failure throws — Swift uses manual `Codable` with
    `try?` on rich, fallback to flat, per audit §3 row "Rich agent
    inventory".
  - `features: [String]` round-trips; unknown wire features land in a
    parallel `[String]` and **do not** enter `Set<Feature>` (§6.2
    intersection rule).
  - `Feature` raw-value mapping: `"cost.budget"` ↔ `.costBudget`,
    `"agent_versions"` ↔ `.agentVersions` (spec §6.2 / [`01-spec-delta.md`](01-spec-delta.md) §3) (8).
- Error code structured context (§12):
  - `LEASE_EXPIRED` carries `at: Date`.
  - `BUDGET_EXHAUSTED` carries `currency: String, attempted: Decimal,
    remaining: Decimal`.
  - `AGENT_VERSION_NOT_AVAILABLE` carries `name, version, available:
    [String]`.
  - `retryable` is a computed property (`false` for all three);
    decoding a wire payload with `retryable: true` for one of these
    codes throws `INVALID_REQUEST` (per [`01-spec-delta.md`](01-spec-delta.md) §2 "non-retryable") (8).
- Job-state decoding: round-trip the six v1.0 states (`pending`,
  `running`, `success`, `error`, `cancelled`, `timed_out`); a
  hypothetical v1.0 `JobState` from the audit (`accepted/queued/…`) is
  deliberately not in the set (4).

### Layer 3 — Session/job state machine (≈25 cases)

**Suite:** `@Suite("Session and job state machines")`.
**Covers:** `Sources/ARCPClient/Session.swift`,
`Sources/ARCPRuntime/SessionContext.swift`,
`Sources/ARCPRuntime/Job.swift`.

Pure state-machine cases driven by a `MemoryTransport` injected into the
session actor; no real network.

- Hello/welcome happy paths: v1.0 client ↔ v1.0 runtime, v1.1 ↔ v1.1,
  v1.0 ↔ v1.1 (degrade), v1.1 ↔ v1.0 (degrade) — the intersection
  matrix from [`01-spec-delta.md`](01-spec-delta.md) §3. After
  negotiation, calling `client.ack(seq:)` against a v1.0 server throws
  `INVALID_REQUEST` locally per §3 of the spec delta (4).
- Welcome rejection paths: missing token → `UNAUTHENTICATED`, malformed
  hello → `INVALID_REQUEST`, runtime sends `session.error` then closes;
  client surfaces typed `ARCPError`, no envelope is sent after close
  (3).
- Resume (§6.3): `resume_token` is rotated on every welcome (a second
  resume with the original token throws `RESUME_WINDOW_EXPIRED`); replay
  starts at `event_seq > last_event_seq`; cross-reconnect monotonicity
  holds (3).
- Heartbeat (§6.4): with `TestClock`, advancing past
  `heartbeat_interval_sec` triggers `session.ping` from runtime; client
  echoes `session.pong`; advancing past `2 × interval` with no pong
  surfaces `HEARTBEAT_LOST` on the client's event stream (3).
- Ack accumulation (§6.5): client `autoAck` debounces to one
  `session.ack` per N events (parameterized: N ∈ {1, 16, 256}); runtime
  `recordAck` is monotonic — an older `last_processed_seq` is ignored
  (3).
- Job lifecycle (§7.3): `pending → running → success`, `→ error`,
  `→ cancelled` (via `job.cancel` within the 30s grace, §7.4),
  `→ timed_out` (driven by `TestClock` past `max_runtime_sec`). Each
  uses `confirmation(expectedCount: 1) { confirm in … }` for the
  terminal event. Invalid transitions (e.g. `success → running`) are
  unreachable at the type level (the `JobState` machine is exhaustive
  in Swift) but a wire-shaped negative test still asserts the runtime
  refuses to emit a second terminal (5).
- `list_jobs` cursor (§6.6): paged read, opaque cursor round-trips, end
  of stream is `next_cursor: nil` (2).
- Agent version (§7.5): `submit(agent: "name@v2")` against a runtime
  advertising `versions: ["v1"]` throws
  `AGENT_VERSION_NOT_AVAILABLE` with `available: ["v1"]` (2).

### Layer 4 — Integration tests (≈20 cases)

**Suite:** `@Suite("Integration — MemoryTransport")` and
`@Suite("Integration — WebSocketTransport loopback")`.
**Covers:** the actor stack end-to-end through the two transports
surviving from the audit
([`Sources/ARCP/Transport/MemoryTransport.swift`](../../Sources/ARCP/Transport/MemoryTransport.swift),
the WS client picked in [`03-libraries.md`](03-libraries.md)).

Each v1.1 feature gets one end-to-end case **on each transport** (the
two suites share a generic `runScenario<T: Transport>(…)` helper). For
the two H-risk areas the audit named (§3), the cases below are
explicit:

- **subscribe (§7.6) — `AsyncStream` lifecycle leak.** Client opens
  `let stream = try await client.subscribe(jobID: …)`. Consume 5
  events. Drop the stream (`break` out of `for try await`, or call
  `_ = consume stream` and exit scope). Assert: the runtime-side
  subscriber count returns to **0** within `Task.yield()` × 16 (no
  fixed sleep). Implementation contract being tested: the
  `AsyncThrowingStream`'s `onTermination` closure on the runtime side
  removes the subscriber entry — the audit §3 row "subscribe" cites
  this as the H-risk Swift idiom. A second case: parallel subscribers
  (10 of them), random drop order; final count is 0.
- **result_chunk (§8.4) — chunk assembly.** Server emits a 5 MiB
  result in 1 MiB chunks (`encoding: "utf8"`). Client collector uses a
  `Data` accumulator with `reserveCapacity` (the architecture contract
  from audit §3, row "result_chunk"). Assert: peak memory ≈ result
  size (no quadratic blow-up — tested by emitting 5 streams in
  parallel and checking final RSS via `mach_task_basic_info` on macOS,
  `/proc/self/statm` on Linux, with a tolerance band). Second case:
  cancel via `Task.cancel()` mid-stream after chunk 3 of 5; assert no
  leaked buffer (the collector's `Data` is released; verified by
  weak-reference probe on a wrapper struct).
- Each remaining v1.1 feature ×2 transports = 16 cases: heartbeat,
  ack, list_jobs, agent_versions, progress, lease_expires_at,
  cost.budget, lease subsetting (delegation). Two of those reuse the
  H-risk subscribers and chunks above on the WS path to confirm
  identical behaviour over the framed transport.

### Layer 5 — Conformance harness (≈1 suite, emits report)

**Suite:** `@Suite("ARCP v1.1 conformance — Swift")` at
`Tests/ARCPConformanceTests/`. Each row of the TS
[`CONFORMANCE.md`](../../../typescript-sdk/CONFORMANCE.md) is one
`@Test` in this suite. Each test's body asserts the requirement holds
and emits one row to a markdown buffer; the suite's `deinit` (or a
test-plan post-action) writes `CONFORMANCE.md` at the SDK root.

Output shape mirrors the TS file row-for-row: `| Requirement | Status |
Location (Swift symbol) |`. "Implemented" means the named Swift test
passed in this run; "Deferred" rows carry the rationale string from
[`01-spec-delta.md`](01-spec-delta.md). The runner declaration:

```
swift test --filter ARCPConformanceTests
```

writes `swift-sdk/CONFORMANCE.md` as a side effect. CI fails if the
file's "Deferred" set diverges from the planned set in
[`10-synthesis.md`](10-synthesis.md).

---

## 3. Concurrency-specific tests

- **`withTimeoutOrNil`.** A package-private helper in
  `Tests/Support/Concurrency.swift`:
  `func withTimeoutOrNil<T: Sendable>(_ duration: Duration, clock: any Clock<Duration> = ContinuousClock(), _ op: @Sendable () async throws -> T) async throws -> T?`
  — wraps `op` in a `withThrowingTaskGroup` that races against
  `clock.sleep(for: duration)`. Every test that touches the actor stack
  uses it (production code path: `withTaskCancellationHandler` so the
  losing branch is cancelled). The helper returns `nil` on timeout so
  call sites `#expect` against an explicit `nil`, not a thrown
  `CancellationError` ambiguity.
- **Explicit `Task.cancel()` paths.** Every long-running async API gets
  a cancellation case:
  - `subscribe`: parent `Task.cancel()` mid-stream → `for try await`
    throws `CancellationError`, runtime subscriber count returns to 0
    (overlaps with Layer 4 H-risk case but tested independently in
    Layer 3).
  - `submit` with `resultChunk`: parent `Task.cancel()` mid-collection
    → collector returns partial `Data`, `job.cancel` envelope is
    emitted by the client.
  - `listJobs` with paging: parent `Task.cancel()` between pages →
    inner `Task.checkCancellation()` in the page-iterator surfaces.
- **No `sleep`-driven races.** `Task.sleep(for:)` and
  `Thread.sleep(forTimeInterval:)` are banned from
  `Tests/`. Enforcement: a `swiftlint` custom rule
  (`no_sleep_in_tests`, regex `Task\.sleep|Thread\.sleep`) plus a
  `grep`-shaped CI step (`grep -r "Task.sleep\|Thread.sleep" Tests/ &&
  exit 1`). `XCTestExpectation`-based async helpers (`expectation`,
  `wait(for:timeout:)`) are deprecated in new code; surviving
  `XCTest` cases retain them only until rewritten.

---

## 4. CI matrix

| Cell                 | Runner                                        | Targets compiled                                                                                                                | Tests run                                            | Rationale                                                                                                                                                                                                                                                       |
| -------------------- | --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| macOS                | `macos-15` GitHub runner, latest released Xcode (verify version at CI-config time — Xcode 16.x as of 2026-05) | All targets: `ARCPCore`, `ARCPClient`, `ARCPRuntime`, `ARCP` umbrella, `ARCPMiddlewareVapor`, `ARCPMiddlewareHummingbird`, `ARCPMiddlewareOTel`, `ARCPConformanceTests`. | All test targets.                                    | Primary dev path; coverage is collected from this cell only (Swift `llvm-cov` is most reliable on macOS).                                                                                                                                                       |
| Linux                | Official `swift:6.0-jammy` Docker image       | `ARCPCore`, `ARCPClient`, `ARCPRuntime`, middleware. **No iOS-only targets.** WS transport per Phase 3's pick (`URLSessionWebSocketTask` on Linux requires swift-corelibs-foundation parity verified — see [`03-libraries.md`](03-libraries.md)). | All non-iOS test targets, including the conformance suite.                                                | Cross-platform confidence. The audit (§2.2) flags `URLSessionWebSocketTask`'s historical Linux lag — the Linux cell catches regressions here before any consumer does.                                                                                          |
| iOS Simulator        | `xcodebuild test` on macOS runner             | `ARCPCore`, `ARCPClient` only. **`ARCPRuntime` does not compile for iOS** (server-side use). The Phase 4 BOOTSTRAP declares iOS 17+ as a public client target. | `ARCPCoreTests`, `ARCPClientTests`. Layer 1–3 only.  | iOS 17+ is in the platform floor (`BOOTSTRAP.md:88` / `Package.swift:platforms`). The runtime is server-only; integration tests against a real runtime stay on macOS+Linux.                                                                                     |

Examples (`Samples/<Name>/`, per
[`06-examples.md`](06-examples.md) when present) run on macOS+Linux
only; iOS skips them. Some examples are marked `darwin-only` (e.g.
`Samples/Stdio/` shells out to `xargs`) and the matrix's Linux cell
excludes them via a `swift test --skip` filter.

---

## 5. Coverage policy

- **Floor: 87% lines.** Collected with `swift test --enable-code-coverage`
  + `llvm-cov export --format=lcov`. Reported via `xcrun llvm-cov
  report` against `.build/debug/codecov/default.profdata`.
- **Branch coverage substitute.** Swift's `llvm-cov` does not emit
  gcov-shaped branch counts (no `-fprofile-arcs`/`-ftest-coverage`
  equivalent for the LLVM front-end). Documented honestly. Substitute:
  `functions ≥ 90%` — function-level coverage is what `llvm-cov`
  reports natively. Branch shape is checked indirectly via parameterized
  `@Test(arguments:)` rows that walk each `switch` discriminant.
- **Exclusions** (via `swift test --skip` and `llvm-cov export
  --ignore-filename-regex`):
  - Test code itself: `--ignore-filename-regex='Tests/.*'`.
  - Auto-generated Codable boilerplate: where manual `Codable` is
    written for a 50-key struct, the synthesized fallbacks are excluded
    by `// LCOV_EXCL_START` / `LCOV_EXCL_STOP` markers around the
    `init(from:)` blocks — `llvm-cov` honours these. Filename regex
    excludes anything in `Generated/` if codegen lands.
  - Examples: `Samples/` is not part of the SDK; excluded by regex
    `Samples/.*`.
- **Where to spend test budget.**

| Where                                                                                                              | Cost     | Coverage yield | Suite                                                                            |
| ------------------------------------------------------------------------------------------------------------------ | -------- | -------------- | -------------------------------------------------------------------------------- |
| Envelope/body `Codable` round-trips                                                                                | Cheap    | High           | Layer 1 + 2 (`Envelope wire format`, `Message bodies`)                           |
| Lease pattern matcher (`compileGlob`/`matchGlob` in `Sources/ARCPRuntime/Lease.swift`) — pure function, table-driven | Cheap    | High           | `@Suite("Lease pattern matcher")` — parameterized rows: 30 fixtures from TS `packages/runtime/src/lease.test.ts` |
| Feature intersection logic (§6.2)                                                                                  | Cheap    | High           | `@Suite("Capability negotiation")` in Layer 3                                    |
| Agent ref parser (`name@version`, §7.5)                                                                            | Cheap    | High           | `@Test(arguments:)` table; reuses the TS test cases verbatim                     |
| WS transport reconnect/resume path                                                                                 | Expensive (loopback server, framing edge cases, Linux/macOS divergence) | Moderate (one big control-flow tree) | Layer 4 `Integration — WebSocketTransport loopback`. Budget: 4 cases (clean reconnect, resume past window, mid-frame disconnect, partial frame). |
| Race-y subscriber teardown                                                                                          | Expensive | High (the H-risk) | Layer 4 `subscribe` cases — see §2 / Layer 4                                     |
| `TestClock` interactions with budget metric decrement (§9.6)                                                       | Expensive (clock + actor reentrancy) | Moderate | `@Suite("Budget — time-travel")` — 3 cases: decrement under metric stream, cross-currency rejection, BUDGET_EXHAUSTED on next op |

The four cheap rows alone cover the bulk of `ARCPCore` (lines-wise the
biggest module). They alone should clear the 87% floor for `ARCPCore`.
The two expensive sets pay for `ARCPClient` and `ARCPRuntime`
coverage.

---

## 6. Test plan in `Package.swift`

One `.testTarget` per public target, plus one top-level conformance
target. Names mirror the module split from
[`02-current-audit.md`](02-current-audit.md) §2.1:

```
.testTarget(name: "ARCPCoreTests",        dependencies: ["ARCPCore"]),
.testTarget(name: "ARCPClientTests",      dependencies: ["ARCPClient", "ARCPCore"]),
.testTarget(name: "ARCPRuntimeTests",     dependencies: ["ARCPRuntime", "ARCPCore"]),
.testTarget(name: "ARCPConformanceTests", dependencies: ["ARCPCore", "ARCPClient", "ARCPRuntime"],
            resources: [.copy("Fixtures/")]),
```

- `Fixtures/` holds the TS-emitted envelope goldens used by the Layer 1
  snapshot cases. They are checked into the repo (≈ 10 KiB total).
- Coverage exclusions are not expressed in `Package.swift` (no such
  knob today); they live in the `.github/workflows/ci.yml` `llvm-cov
  export` invocation as `--ignore-filename-regex`. Inline `LCOV_EXCL`
  markers cover the synthesized-`Codable` exclusion case.
- `swiftSettings` on each test target carry the same
  `.swiftLanguageMode(.v6)` and `.enableUpcomingFeature("ExistentialAny")`
  as the production targets — strict-concurrency violations in tests
  must fail the build, not be tolerated as "test code".
- A test plan file (`ARCP.xctestplan`) is generated only if iOS CI
  needs it for `xcodebuild test`; SwiftPM-only runs on macOS and Linux
  use `swift test --filter` to select sub-suites.

---

## Anti-slop check

Every entry above cites either a spec § (`§5.1`, `§6.2`, `§6.4`, `§6.5`,
`§6.6`, `§7.3`, `§7.4`, `§7.5`, `§7.6`, `§8.2`, `§8.2.1`, `§8.4`, `§9.5`,
`§9.6`, `§12`), a current SDK or TS path
(`Sources/ARCP/Transport/MemoryTransport.swift`,
`typescript-sdk/packages/runtime/src/lease.test.ts`), or a Swift idiom
(`AsyncThrowingStream`, `Task.checkCancellation`, `ContinuousClock`,
`TestClock`, `confirmation`, `Sendable`). The two H-risk cases come
verbatim from [`02-current-audit.md`](02-current-audit.md) §3; no
hypothetical bugs are tested.
