# 03 — Dependencies

Every pick is defended against `Foundation` and `swift-nio`. If
`Foundation` does the job, no dep is added. Targets named here line up
with the split planned in
[`04-architecture.md`](04-architecture.md): `ARCPCore`, `ARCPClient`,
`ARCPRuntime`, plus opt-in `ARCPMiddleware*` adapters.

## JSON encoding/decoding — `Foundation.JSONEncoder` / `JSONDecoder`

**Pick:** Stdlib `Foundation.JSONEncoder` / `JSONDecoder`. No dep.

Why over `apple/swift-foundation`: on Swift 6.x toolchains the Linux
build already vends the rewritten Foundation, so `Foundation` is
parity-equivalent without a separate package import — adding
`swift-foundation` only buys us a version skew risk. Why over
`swift-extras/swift-extras-json`: §5.1 "unknown top-level fields MUST
be ignored" is already the default behavior of `JSONDecoder`; the
performance argument that drives `swift-extras-json` adoption does not
clear ARCP's bar (envelopes are small, the bottleneck is the
WebSocket).

Caveats locked in by spec §5.1 / §8.4: enable
`.dateEncodingStrategy = .iso8601` with fractional seconds (the
existing
[`Envelope/Envelope.swift:191`](../../Sources/ARCP/Envelope/Envelope.swift#L191)
`ISO8601DateFormatter` cache survives), and set
`.keyDecodingStrategy = .useDefaultKeys` because the wire spec uses
snake_case explicitly (`event_seq`, `session_id`, `last_processed_seq`)
— do not enable `convertFromSnakeCase`.

Repo: stdlib. **Verify before commit:** that `JSONEncoder` on the
Swift 6.1 Linux toolchain handles `Decimal` round-trips for
`cost.budget` amounts without `Double` widening (it does in
swift-foundation; the legacy corelibs path did not).

Rejected:
- `swift-foundation`: redundant on 6.1+; one more package version to
  pin.
- `swift-extras-json`: no `Decimal` codable path on its `JSONValue`
  enum, which is the one place we can't compromise (§9.6,
  `01-spec-delta.md` §4).

## WebSocket — client — `URLSessionWebSocketTask`

**Pick:** `URLSessionWebSocketTask` from `Foundation`.

Why over `vapor/websocket-kit`: the current SDK's choice
([`Package.swift:22`](../../Package.swift#L22)) already hit the
documented footgun — "`WebSocketKit.WebSocket`'s server-side
initializer is internal" per the audit
([`02-current-audit.md`](02-current-audit.md#1-v10-conformance) §4.1).
Why over raw `swift-nio` + a hand-rolled HTTP/1.1 → WebSocket upgrade:
`NIOWebSocket` works but pulls `NIOPosix` and an `EventLoopGroup` into
`ARCPClient`, which contradicts the architecture rule "core/client
shouldn't depend on NIO transitively"
([`02-current-audit.md`](02-current-audit.md#21-packageswift-decoded)).

`URLSessionWebSocketTask` has been on Linux since
swift-corelibs-foundation gained it in Swift 5.7 and is fully present
in the Swift 6.x `swift-foundation` rewrite. It is `Sendable`-clean,
supports `Task.cancel()` (closes the socket with code 1001), and
exposes `send(.string)` / `receive()` which map directly to ARCP's
text-frame-only contract (§4.1). **Verify before commit:**
TLS-redirect handling and proxy-CONNECT behavior on the Linux 6.1
runtime — the corelibs path historically diverged from Darwin
`NSURLSession` here.

Cancellation idiom: wrap the receive loop in
`withTaskCancellationHandler` so the actor that owns the task
(`ARCPClient`) can `task.cancel(with:.goingAway, reason:nil)` without
racing the read continuation.

Repo: stdlib. No version to pin.

Rejected:
- `vapor/websocket-kit` (2.15.x): server initializer internal; pulls
  in NIO transitively; auto-pings on a `NIOEventLoop` schedule we
  cannot easily wire to `ContinuousClock` for §6.4 monotonic-interval
  heartbeats.
- Raw `swift-nio` + custom upgrade: maintenance burden (Sec-WebSocket
  framing, ping/pong, close-frame state machine) for no win over
  `URLSessionWebSocketTask` on a client.

## WebSocket — server — `swift-nio` (`NIOWebSocket`) + `swift-nio-extras`

**Pick:** `swift-nio` + `swift-nio-extras`, exposed as a default
in-tree transport (`ARCPNIOServer`). Vapor / Hummingbird adapters live
in opt-in middleware targets (`ARCPVapor`, `ARCPHummingbird`) per the
middleware plan in
[`05-middleware.md`](05-middleware.md).

**Does core ship a server transport?** Yes — but only the raw NIO
one. The SDK ships `ARCPRuntime` + a `swift-nio`-backed transport so
the example servers in
[`06-examples.md`](06-examples.md) run via `swift run` with zero host
framework. A host adapter is the path for production deployment, and
the runtime exposes a `Transport` seam
([`Transport/Transport.swift`](../../Sources/ARCP/Transport/Transport.swift))
that Vapor's `WebSocket` or Hummingbird's
`HTTPChannelHandler.upgrade(to: .websocket(...))` plugs into. The
adapter owns DNS-rebind / Host-header checks (§14 / `05-middleware.md`).

Why over `vapor/vapor` as the core dep: Vapor pulls `swift-nio`,
`async-http-client`, `routing-kit`, `console-kit`, and a sizable
runtime — too much surface to push onto users of `ARCPRuntime` who
only need a socket. Why over
`hummingbird-project/hummingbird-websocket`: same argument, smaller
footprint than Vapor but still imposes a framework choice that
ARCPRuntime does not need to make.

Repo: `apple/swift-nio` (already in `Package.swift:21`), pin
`from: "2.74.0"`; `apple/swift-nio-extras` for `RequestResponseHandler`
+ `LineBasedFrameDecoder` pieces if needed.

Rejected:
- `vapor/vapor`: framework-shaped; mandates Application lifecycle.
- `hummingbird-websocket`: better candidate than Vapor for core, but
  the rule is "no framework in core" — punt to adapter.

## HTTP — `URLSession`, gated on actual need

**Pick:** `URLSession` from `Foundation`, only inside opt-in
middleware (`ARCPMiddlewareAuth` for JWKS fetch). **Not in core**.

**Does the SDK need HTTP?** ARCP is WebSocket-first; §4 lists HTTP/2
as optional, and v1.1 adds no HTTP-only message. The core never
issues an HTTP request. The only realistic HTTP caller is a future
JWT-validation middleware that needs JWKS rotation, which is exactly
the kind of thing that belongs out-of-core
([`02-current-audit.md`](02-current-audit.md#21-packageswift-decoded)).

Why over `apple/swift-async-http-client`: `swift-async-http-client`
pulls NIO into a target that, by the architecture rule, must not
depend on NIO. For a single low-volume JWKS GET, `URLSession.data(for:)`
is sufficient on both Darwin and Linux 6.1.

If a future feature requires keepalive HTTP/2 multiplexing at volume
(e.g. a hosted runtime that fans out webhooks), reopen this and add
`async-http-client` to the specific middleware only.

Repo: stdlib.

Rejected:
- `swift-async-http-client`: too much weight for an optional code
  path; reintroduces the NIO transitive that core specifically avoids.

## Concurrency — Swift stdlib structured concurrency

**Pick:** Stdlib only. No dep.

Policy (binding for [`04-architecture.md`](04-architecture.md) and
all subagents):

- `async` / `await` on every public entry; no completion handlers.
- Cooperative multitasking via `TaskGroup`, `async let`,
  `withThrowingTaskGroup` for fan-out (e.g. concurrent `job.list`
  pagination).
- `AsyncSequence` / `AsyncStream` / `AsyncThrowingStream` for
  streams. `subscribe` returns `AsyncThrowingStream<JobEvent, Error>`
  with `bufferingPolicy: .bufferingNewest(N)`; `onTermination` frees
  the runtime-side subscriber entry (the H-risk in
  [`02-current-audit.md`](02-current-audit.md#3-gap-matrix--v11-feature--missingpartialpresent)).
- Cancellation through `Task.checkCancellation()` plus
  `withTaskCancellationHandler { ... } onCancel: { ... }` on transport
  operations.
- No `DispatchQueue` on the public surface (existing code already
  complies — [`02-current-audit.md`](02-current-audit.md#23-sendable--actor-isolation-status)).
- `actor` for session/job state; `Sendable` annotations on every
  public type; `@unchecked Sendable` is forbidden in core.

No third-party concurrency library is justified. `swift-async-algorithms`
would be a candidate for `debounce` on auto-ack
([`02-current-audit.md`](02-current-audit.md#3-gap-matrix--v11-feature--missingpartialpresent),
§6.5 row), but a hand-rolled `AsyncStream` + `ContinuousClock`
coalescer is cheaper than another dep — defer.

## Logging — `apple/swift-log`

**Pick:** `apple/swift-log`. Keep.

The SDK obtains a `Logger` via `Logger(label: "arcp.client")` and ships
**no `LogHandler`**. The consumer's `LoggingSystem.bootstrap` chooses
the backend. Rationale: ARCP is a library shipped into hosts that
already have a logging policy (server hosts use
`swift-log-cloudwatch`, `swift-log-otel`, etc.); shipping a backend
would either fight the host's bootstrap or silence the host's
backend.

Repo: `https://github.com/apple/swift-log`, already pinned
`from: "1.6.0"` ([`Package.swift:19`](../../Package.swift#L19)). No
change.

## Metrics — `apple/swift-metrics` (exclude)

**Pick:** Exclude. No dep.

Defense: ARCP's metric channel is in-band — agents emit
`job.event { kind: "metric" }` (§8.2) and the runtime decrements the
`cost.*` counters per §9.6. There is no host-level meter the SDK
should be writing to; the host adapter
([`05-middleware.md`](05-middleware.md)) can re-emit selected
in-band metrics into `swift-metrics` if it wants, but the
core/client/runtime do not own that mapping. Adding `swift-metrics`
to core means every consumer pulls a `MetricsSystem.bootstrap`
contract for no in-tree call site.

Repo: not added.

## Tracing — `apple/swift-distributed-tracing` (middleware only)

**Pick:** `apple/swift-distributed-tracing` (the API package), wired
through an opt-in `ARCPMiddlewareOTel` target. The OTel exporter
itself is `slashmo/swift-otel`.

Not in core. Core only carries the W3C `trace_id` validator already
present at
[`Trace/TraceContext.swift`](../../Sources/ARCP/Trace/TraceContext.swift)
and the `traceparent` field on the envelope (§11). The middleware
imports `Tracing` (the `swift-distributed-tracing` API target) and
starts spans per envelope, applying the v1.1 attribute set
(`arcp.session_id`, `arcp.job_id`, `arcp.agent`,
`arcp.lease.capabilities`, plus the v1.1 additions
`arcp.lease.expires_at` and `arcp.budget.remaining` per §11 and
[`01-spec-delta.md`](01-spec-delta.md)).

Why `swift-otel` over `open-telemetry/opentelemetry-swift`: the
former is the ServerSide Swift WG / SSWG-incubating exporter built on
the `swift-distributed-tracing` API; the latter is an OTel-spec
implementation that does not consume `swift-distributed-tracing` and
forces a parallel tracer surface on the host. `swift-otel` is the
only option that lets the host's existing tracer-bootstrap also
collect ARCP spans without double-instrumentation.

Repo: `https://github.com/apple/swift-distributed-tracing`,
`from: "1.1.0"` — verify before commit. `https://github.com/slashmo/swift-otel`
— verify the current release tag before commit. Both live in
`ARCPMiddlewareOTel` only.

Rejected:
- `opentelemetry-swift`: doesn't compose with the SSWG tracing API;
  forces hosts to bootstrap two tracers.

## IDs — `Foundation.UUID` (UUIDv4) + in-tree ULID generator

**Pick:** Keep the in-tree generator at
[`Sources/ARCP/Ids/Ulid.swift`](../../Sources/ARCP/Ids/Ulid.swift). No
dep.

`Foundation.UUID` is UUIDv4 only as of Swift 6.x; there is no
`UUID.v7()` in stdlib or Foundation. Two choices: in-tree ULID, or
`lukaskubanek/swift-ulid`.

Why in-tree over `lukaskubanek/swift-ulid`: §5.1 only requires
ULID-or-UUIDv7 lexicographic-sortable identifiers, and the existing
[`Ulid.swift`](../../Sources/ARCP/Ids/Ulid.swift) generator already
ships Crockford-base32 + monotonic-within-millisecond increments. It
is in the audit's salvage list
([`02-current-audit.md`](02-current-audit.md#4-salvage-list--what-survives-the-migration)).
The third-party package is ~400 lines and adds a package boundary for
a primitive that does not benefit from being externalized.

If §5.1 ever requires true UUIDv7 (not ULID), revisit and add a
6-byte-Unix-millis + 10-bit-random-A + 62-bit-random-B generator
in-tree; do not add a dep.

Repo: in-tree. No version to pin.

Rejected:
- `lukaskubanek/swift-ulid`: tiny win, adds a release-track dep for a
  one-file primitive.

## Decimal arithmetic — `Foundation.Decimal`

**Pick:** `Foundation.Decimal`. No dep.

`Decimal` is the budget-amount type (§9.6 +
[`01-spec-delta.md`](01-spec-delta.md) §4). `Double` is **rejected**
— floating-point silently corrupts cent values and the
`USD:5.00`-style amount-string grammar is decimal-exact. `Decimal`
is `Sendable` (value type), supports the four basic operators, and
encodes as a JSON number through `JSONEncoder` on Swift 6.1+.

Cross-currency arithmetic guard
([`01-spec-delta.md`](01-spec-delta.md) §4): `Budget` carries
`(currency: Currency, amount: Decimal)`. Adding two `Budget`s with
different currencies is a programmer error — debug builds
`precondition(lhs.currency == rhs.currency)`, release returns
`lhs` (a meaningless cross-currency sum is never silently produced).
`Currency` is a `String` wrapper (the spec leaves the set open per
§9.6 + [`01-spec-delta.md`](01-spec-delta.md) §4), not a closed enum.

Repo: stdlib.

## Clocks — `ContinuousClock` for elapsed, `Date` for serialization

**Pick:** Stdlib `ContinuousClock` (elapsed) + `Foundation.Date`
(wire). No dep.

Spec §14 requires a "monotonic, NTP-disciplined clock" for
`lease_expires_at` enforcement. `Foundation.Date` is wall-time and
jumps backward on NTP adjustment — it is the wrong clock for §9.5
expiry decisions. `ContinuousClock.now` is monotonic across NTP
slews; `SuspendingClock` pauses across machine suspend (acceptable
for §6.4 heartbeats but wrong for lease expiry, which must continue
to tick while the host sleeps).

Binding:
- §9.5 `lease_expires_at` enforcement: compare against
  `ContinuousClock.Instant`. The wire form is serialized as
  ISO-8601 `Date`; convert by anchoring at session-welcome and
  carrying the delta forward on `ContinuousClock`.
- §6.4 heartbeat interval timer: `ContinuousClock` for the
  `heartbeat_interval_sec` tick. Existing code uses `Date` here
  ([`02-current-audit.md`](02-current-audit.md#5-strict-concurrency-planning-items-for-04-architecturemd)
  flags `LeaseManager.swift:49,83`) — wrong, rewrite.
- §6.4 `ping.sent_at` / `pong.received_at` wire fields: `Date` (the
  spec requires an ISO-8601 timestamp; monotonicity does not apply
  to a wire field a peer cannot trust).

Repo: stdlib.

## Testing — `swift-testing` (new) + `XCTest` (compat)

**Pick:** `swift-testing` for new tests; existing XCTest cases stay
until rewritten. Snapshots: `pointfreeco/swift-snapshot-testing`,
scoped to envelope round-trip fixtures.

Policy:
- All new test files use `import Testing` and `@Test` macros
  (Swift 6.1 toolchain floor, per
  [`Package.swift:1`](../../Package.swift#L1)).
- The existing `Tests/ARCPTests/` XCTest harness is preserved during
  the v1.0-alignment milestone; ports happen incrementally as files
  are touched.
- `swift-testing`'s parameterized `@Test(arguments:)` covers the
  capability negotiation matrix (§6.2) and the error-code mapping
  table ([`01-spec-delta.md`](01-spec-delta.md) §2).
- `swift-snapshot-testing` earns its keep for one thing: golden
  envelope-fixture round-trips against
  `typescript-sdk/packages/core/test/fixtures/*.json` — the easiest
  way to catch wire-shape drift between SDKs. Limit to
  `Tests/ARCPSnapshotTests/`; do not let it sprawl into UI-style
  snapshots that don't exist for a server library.

Time travel: `swift-testing` does not ship a `Clock` mock the way
`async-algorithms` does; the test plan in
[`07-tests.md`](07-tests.md) owns the `TestClock` shape (small
in-tree mock conforming to Swift's `Clock` protocol).

Repos:
- stdlib `swift-testing` (bundled with the toolchain).
- `https://github.com/pointfreeco/swift-snapshot-testing` —
  verify before commit; pin `from: "1.18.0"` is a reasonable starting
  guess, but confirm the latest minor.

## Coverage — `swift test --enable-code-coverage` + `llvm-cov`

**Pick:** Stdlib toolchain. No dep.

`swift test --enable-code-coverage` emits a `.profdata`; `llvm-cov
export -format=lcov` produces lcov for CI.

**Substitute branch metric:** Swift's coverage instrumentation reports
**lines and functions**, not branches in the gcov sense. CI gates on
**line coverage + function coverage** as the substitute. The
[`07-tests.md`](07-tests.md) plan commits to **87% line / 90%
function** as the floor. Branch coverage as understood from
gcc/gcov is not available; do not write a CI check that pretends it
is.

Excluded paths (per Package.swift test plan in
[`07-tests.md`](07-tests.md)): generated DocC sources, the CLI's
`main`, NIO bootstrap shims with no decisions in them.

Repo: stdlib.

## Lint / format — `apple/swift-format` (format) + `realm/SwiftLint` (lint)

**Pick:** Both, with non-overlapping roles.

- `swift-format` — formatter and style enforcer. Already pinned at
  [`Package.swift:28`](../../Package.swift#L28). Used via
  `swift package plugin format-source-code`. The configuration file
  is `.swift-format` at repo root. Rationale: it is the Apple-owned
  tool that tracks the language's evolution (Swift 6 syntax, macros,
  `~Copyable`), and SwiftLint has historically lagged on new syntax.
- `SwiftLint` — semantic lint rules `swift-format` does not own:
  `redundant_void_return`, `force_unwrapping`, `discouraged_optional_boolean`,
  the custom rule that bans `DispatchQueue` and `@unchecked Sendable`
  in `Sources/ARCP/**`. Run as a SwiftPM plugin in CI; not blocking
  for incremental builds locally.

If only one had to remain: `swift-format` wins because Apple-owned +
syntax-current. SwiftLint is the second, narrower line of defense
specifically for the Sendable/`DispatchQueue` ban.

Repos:
- `https://github.com/apple/swift-format` (already pinned
  `from: "600.0.0"`).
- `https://github.com/realm/SwiftLint` — pin via the SwiftPM plugin
  (verify the current tag before commit).

## Build — SwiftPM only

**Pick:** SwiftPM. No Xcodeproj checked in.

`swift build` / `swift test` are the only supported entry points.
Xcode generates a project from `Package.swift` on demand for
contributors who want the IDE; the generated file is gitignored.
Rationale: ARCP is a server-side SDK; the Linux CI path is a
first-order constraint, and SwiftPM is the only build system that
works identically on macOS, Linux, and CI containers.

DocC plugin and swift-format plugin are SwiftPM plugins, declared in
the `Package.swift` `dependencies` block and invoked via
`swift package plugin …`.

Repo: stdlib.

---

## What changes in `Package.swift`

**Drop:**
- `vapor/jwt-kit` (`Package.swift:26`) — out of core. The bearer-token
  auth in §6.1 is a string check, not a JWT verify. If a host needs
  JWT (asymmetric verification + JWKS rotation), that's a dedicated
  `ARCPMiddlewareJWT` target the host opts into. Note this also
  resolves the Swift 6.2 / MLDSA pin justification in
  [`Package.swift:23-25`](../../Package.swift#L23-L25) — by dropping,
  the constraint disappears.
- `stephencelis/SQLite.swift` (`Package.swift:27`) — out of core
  default. Moves to opt-in `ARCPStoreSQLite` per
  [`02-current-audit.md`](02-current-audit.md#21-packageswift-decoded).
  Resource `Store/Resources/schema.sql` moves with it.
- `vapor/websocket-kit` (`Package.swift:22`) — replaced by
  `URLSessionWebSocketTask` on the client; server side covered by
  `swift-nio` directly. Documented footgun
  ([`02-current-audit.md`](02-current-audit.md#1-v10-conformance)
  §4.1).

**Add:**
- `apple/swift-distributed-tracing` — in `ARCPMiddlewareOTel` only.
- `slashmo/swift-otel` — in `ARCPMiddlewareOTel` only.
- `pointfreeco/swift-snapshot-testing` — in `ARCPTests` /
  `ARCPSnapshotTests` only.
- `realm/SwiftLint` (plugin) — repo-level, not a runtime dep.

**Keep:**
- `apple/swift-log` (1.6+).
- `apple/swift-argument-parser` (1.5+) — `arcp-cli` only.
- `apple/swift-nio` (2.74+) — `ARCPRuntime` (for `NIOWebSocket`
  server transport) and `ARCPNIO` middleware. **Not** in `ARCPCore`
  or `ARCPClient`.
- `apple/swift-format` (600+) — dev plugin.
- `swiftlang/swift-docc-plugin` (1.4+) — dev plugin.

**Platforms:**

```swift
platforms: [
    .macOS(.v14),
    .iOS(.v17),
]
```

Linux is implicit (no platform declaration needed; SwiftPM treats any
non-listed platform as supported by default). CI runs Linux Swift
6.1 explicitly per [`07-tests.md`](07-tests.md).

**Before / after diff (sketch):**

```diff
 dependencies: [
     .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
     .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
     .package(url: "https://github.com/apple/swift-nio.git", from: "2.74.0"),
-    .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.15.0"),
-    .package(url: "https://github.com/vapor/jwt-kit.git", "5.1.0"..<"5.3.0"),
-    .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.3"),
     .package(url: "https://github.com/apple/swift-format.git", from: "600.0.0"),
     .package(url: "https://github.com/swiftlang/swift-docc-plugin.git", from: "1.4.0"),
+    // Middleware-only:
+    .package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.1.0"),
+    .package(url: "https://github.com/slashmo/swift-otel.git", from: "0.9.0"), // verify
+    // Test-only:
+    .package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", from: "1.18.0"), // verify
 ],
```

Target restructuring (the merge from the single `ARCP` target to
`ARCPCore` / `ARCPClient` / `ARCPRuntime` plus middleware targets) is
owned by [`04-architecture.md`](04-architecture.md); this file only
states the dep choices that constrain it.
