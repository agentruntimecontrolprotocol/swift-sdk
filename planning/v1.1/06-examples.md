# 06 — Examples

Mirror of the 23 TypeScript examples (`typescript-sdk/examples/README.md`,
cross-referenced from `typescript-sdk/CONFORMANCE.md` §13) onto Swift,
under `swift-sdk/Samples/`. Each example is one `executableTarget`
declared in the root `Package.swift`, runnable as
`swift run <ExampleName>`, exiting 0 on success. No mocks, no
host-app shells — each example is a `Server.swift` + `Client.swift`
pair plus the shared `ExampleHarness` library target.

This phase replaces the existing illustrative `Samples/` (per-sample
`Package.swift`, stub-driven, non-runnable; see
[`Samples/README.md`](../../Samples/README.md)). Those exist on the
wrong spec lineage (audit §0); the new layout is single-Package,
single-test-`swift run` invocation per example.

## 1. TS → Swift mapping

The "Swift idiom" column names the construct the example exists to
demonstrate. Spec § cites `spec/docs/draft-arcp-02.1.md`.

### v1.0 core (9)

| TS                    | Swift sample                  | Files                                                    | Spec §            | Swift idiom                                                                                                                                                                                          |
| --------------------- | ----------------------------- | -------------------------------------------------------- | ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `submit-and-stream/`  | `Samples/SubmitAndStream/`    | `Server.swift`, `Client.swift`                           | §13.1, §7.1, §8.2 | Client consumes `AsyncThrowingStream<JobEvent, Error>` from `handle.events` with `for try await`. Server emits 7 of 8 v1.0 event kinds via `JobContext.emit(kind:body:)`.                            |
| `delegate/`           | `Samples/Delegate/`           | `Server.swift`, `Client.swift`                           | §13.2, §10        | Parent agent calls `try await ctx.delegate(agent:input:leaseRequest:)`; result `JobHandle` is awaited inside the parent `TaskGroup`. Child `trace_id` is inherited via `TraceContext` value passing. |
| `resume/`             | `Samples/Resume/`             | `Server.swift`, `Client.swift`                           | §13.3, §6.3       | Client tears its `Transport` down with `await transport.close()`, then `ARCPClient.connect(resume:)` passes `{sessionId, resumeToken, lastEventSeq}`; replay events fed back into the same stream.   |
| `idempotent-retry/`   | `Samples/IdempotentRetry/`    | `Server.swift`, `Client.swift`                           | §13.5, §7.2       | Two `client.submit(..., idempotencyKey: "k")` calls return the same `JobHandle.jobId`; third with different `agent` throws `ARCPError.duplicateKey(existingJobId:)`.                                 |
| `lease-violation/`    | `Samples/LeaseViolation/`     | `Server.swift`, `Client.swift`                           | §13.4, §9.3       | Agent calls `try validateLeaseOp(lease, capability: .fsRead, target: path)`; the `throw` surfaces as a `tool_result` body carrying `PERMISSION_DENIED`, then the job continues and `job.result`-s.   |
| `cancel/`             | `Samples/Cancel/`             | `Server.swift`, `Client.swift`                           | §7.4              | Server agent runs inside `withTaskCancellationHandler`; the body loops on `try Task.checkCancellation()`. Client calls `await handle.cancel(reason:)`. Grace timed by `ContinuousClock`.             |
| `stdio/`              | `Samples/Stdio/`              | `Server.swift`, `Client.swift`                           | §4.2, §22         | Single-process example: client spawns server via `Foundation.Process`, connects through `StdioTransport(input:output:)` over its stdin/stdout `FileHandle`s.                                         |
| `vendor-extensions/`  | `Samples/VendorExtensions/`   | `Server.swift`, `Client.swift`                           | §8.2, §9.2, §15   | Agent emits `kind: "x-vendor.acme.progress"` via `ctx.emit(kind:body:)`. Client switches on `JobEvent.kind` — unknown kinds hit the `default` case and are dropped (no decode failure).              |
| `custom-auth/`        | `Samples/CustomAuth/`         | `Server.swift`, `Client.swift`                           | §6.1              | Server provides a `BearerVerifier` conformance (HMAC over SHA-256 via `CryptoKit.HMAC`); bad token surfaces as `ARCPError.unauthenticated` thrown from `client.connect()`.                           |

### v1.1 features (9)

| TS                    | Swift sample                  | Files                                                    | Spec §       | Swift idiom                                                                                                                                                                                                                  |
| --------------------- | ----------------------------- | -------------------------------------------------------- | ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `heartbeat/`          | `Samples/Heartbeat/`          | `Server.swift`, `Client.swift`                           | §6.4         | Server advertises `heartbeat_interval_sec` in `session.welcome`. The session actor schedules pings with `ContinuousClock.sleep(for: .seconds(interval))` (monotonic, not `Date`). `session.ping`/`pong` skip `event_seq`.     |
| `ack-backpressure/`   | `Samples/AckBackpressure/`    | `Server.swift`, `Client.swift`                           | §6.5, §8.2   | Client opts into `ARCPClient.autoAck(every: 32, every: .milliseconds(250))`; auto-ack `Task` lives on the client actor. Server emits a `status { phase: "back_pressure" }` event when its outstanding-seq window exceeds N.   |
| `list-jobs/`          | `Samples/ListJobs/`           | `Server.swift`, `Client.swift`                           | §6.6         | Client calls `try await client.listJobs(filter: .init(status: .running), limit: 10)`. Cursor pagination via `while let cursor = page.nextCursor` loop. Result is `[JobListEntry]` — Sendable value types.                     |
| `subscribe/`          | `Samples/Subscribe/`          | `Server.swift`, `ClientA.swift`, `ClientB.swift`         | §7.6, §6.6   | Returns `AsyncThrowingStream<JobEvent, Error>` with `onTermination = { _ in Task { await runtime.unsubscribe(jobId) } }` so cancelling the consumer Task frees the runtime entry. Subscriber's `handle.cancel()` throws `PERMISSION_DENIED`. |
| `agent-versions/`     | `Samples/AgentVersions/`      | `Server.swift`, `Client.swift`                           | §7.5, §12    | `try parseAgentRef("code-refactor@2.0.0")` returns `AgentRef(name:version:)`; bare `"code-refactor"` resolves via `ARCPServer.setDefaultAgentVersion(_:_:)`; unregistered version throws `.agentVersionNotAvailable(available:)`. |
| `lease-expires-at/`   | `Samples/LeaseExpiresAt/`     | `Server.swift`, `Client.swift`                           | §9.5, §12    | `LeaseConstraints(expiresAt: Date)` serialized as ISO-8601-with-Z. Runtime watchdog uses `ContinuousClock` for the elapsed-time comparison; `Date` is only the wire form. Trips `ARCPError.leaseExpired(at:)`.                |
| `cost-budget/`        | `Samples/CostBudget/`         | `Server.swift`, `Client.swift`                           | §9.6, §12    | `Budget(amounts: [Currency("USD"): Decimal(string: "5.00")!])` — `Decimal` (not `Double`) throughout. `ctx.metric(name:"cost.tokens", value: Decimal("0.20"), unit:"USD")` decrements; final op throws `.budgetExhausted`.    |
| `progress/`           | `Samples/Progress/`           | `Server.swift`, `Client.swift`                           | §8.2.1       | Agent calls `ctx.progress(current: i, total: total, units: "files", message: nil)`. Client switches on `JobEvent.kind == .progress` and renders an in-place `print` bar guarded by `isatty`.                                  |
| `result-chunk/`       | `Samples/ResultChunk/`        | `Server.swift`, `Client.swift`                           | §8.4         | Agent: `let writer = ctx.streamResult(resultId:); for s in chunks { try await writer.write(.utf8(s)) }; try await writer.finish()`. Client: `for try await chunk in handle.chunks() { data.append(chunk.bytes) }` — `Data` accumulator with `reserveCapacity` to dodge O(n²) `String` concat (audit §3 result_chunk H-risk). |

### Host integrations (5)

| TS          | Swift sample              | Files                                                    | Spec § | Swift idiom                                                                                                                                                                                                                |
| ----------- | ------------------------- | -------------------------------------------------------- | ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `tracing/`  | `Samples/OtelTracing/`    | `Server.swift`, `Client.swift`                           | §11    | Both sides bootstrap `swift-distributed-tracing` with `swift-otel`'s `OTel.Tracer` (per `03-libraries.md`). `ARCPOTel` middleware attaches a span per envelope and sets `arcp.session_id`, `arcp.job_id`, `arcp.agent`, `arcp.lease.capabilities`, `arcp.lease.expires_at`, `arcp.budget.remaining`. Trace context rides `extensions["x-vendor.opentelemetry.tracecontext"]`. Console span exporter so the example self-prints. |
| `express/`  | `Samples/Vapor/`          | `Server.swift`, `Client.swift`                           | §4.1   | `app.arcp.attach(at: "/arcp", server: arcpServer, allowedHosts: ["127.0.0.1"])` — single Vapor `Application` serving both regular routes and the ARCP WS upgrade. `allowedHosts` enforces the DNS-rebind check inside the upgrader.                                                                                          |
| `fastify/`  | `Samples/Hummingbird/`    | `Server.swift`, `Client.swift`                           | §4.1   | `hummingbirdRouter.attachARCP(at: "/arcp", server: arcpServer, logger: app.logger)` — Hummingbird `Application` with structured `swift-log` (replaces TS pino), `Logger.MetadataValue` carrying per-request id, all on the same port.                                                                                       |
| `bun/`      | —                         | —                                                        | —      | Dropped. Bun is a JS-runtime example; Swift has no equivalent runtime substitution. Folding it into `Samples/Stdio/` or `Samples/Vapor/` would just duplicate. Stated explicitly in §5.                                                                                                                                       |
| `node/`     | `Samples/NIO/`            | `Server.swift`, `Client.swift`                           | §4.1   | Framework-free server via `ARCPNIO` (per `05-middleware.md`): raw `NIOHTTP1` upgrade + `WebSocketKit` channel handler, no Vapor/Hummingbird. Mirrors TS `@arcp/node` (which is "WS over a raw Node HTTP server"). Demonstrates the bare-NIO seam for embedders that already have their own server. |

Total mapped: 22 (9 + 9 + 4). `bun` dropped; net count is 22, not 23.

## 2. Sample directory layout

```
swift-sdk/
├── Package.swift                       (one root manifest)
├── Sources/
│   ├── ARCP/                           (umbrella)
│   ├── ARCPCore/  ARCPClient/  ARCPRuntime/
│   ├── ARCPVapor/  ARCPHummingbird/  ARCPNIO/  ARCPOTel/
│   └── ExampleHarness/                 (internal, not a public product)
└── Samples/
    ├── SubmitAndStream/
    │   ├── Server.swift
    │   └── Client.swift
    ├── Delegate/
    │   ├── Server.swift
    │   └── Client.swift
    ├── Resume/                  ├── IdempotentRetry/
    ├── LeaseViolation/          ├── Cancel/
    ├── Stdio/                   ├── VendorExtensions/
    ├── CustomAuth/              ├── Heartbeat/
    ├── AckBackpressure/         ├── ListJobs/
    ├── Subscribe/               ├── AgentVersions/
    ├── LeaseExpiresAt/          ├── CostBudget/
    ├── Progress/                ├── ResultChunk/
    ├── OtelTracing/             ├── Vapor/
    ├── Hummingbird/             └── NIO/
```

Hard constraints:

- **Single root `Package.swift`.** Each example is declared as an
  `.executableTarget(name: "<Name>", dependencies: [...], path: "Samples/<Name>")`.
  No per-sample `Package.swift`. (Reverses the current
  per-sample-manifest convention in `Samples/README.md` — that pattern
  predates this migration and made `swift run <Name>` impossible from
  the SDK root.)
- **Run invocation.** `swift run SubmitAndStream`, `swift run Resume`,
  etc. The target name is the directory name.
- **Default transport: `MemoryTransport`** (audit §4 salvage row). The
  in-process loop has no port, no auth boilerplate, and removes
  flakiness from CI. Only six examples need a real transport:
  `Stdio/` (stdio pipe), `Resume/` (must reconnect, so
  `MemoryTransport` + an explicit `close()`/new-instance dance works),
  `OtelTracing/`, `Vapor/`, `Hummingbird/`, `NIO/` (the four host
  integrations exercise WebSocket).
- **Exit code contract.** Every `Client.swift` ends with a single
  `succeed()` (zero) or `fail(reason)` (non-zero) call from the
  harness. A CI script can match on exit code alone.
- **Linkage.** Each example links `ARCP` (the umbrella). Host
  integrations add the relevant middleware target. `OtelTracing/` adds
  `ARCPOTel`. `Vapor/`, `Hummingbird/`, `NIO/` add their respective
  middleware targets. The internal `ExampleHarness` is a dependency
  of every example.

## 3. Common harness — `ExampleHarness`

An `internal` library target (no `library` product) supplies the
shared scaffolding. Surface area, with one-line per helper:

- `func makeMemoryServer(_ configure: (ARCPServer) -> Void) async throws -> (ARCPServer, ARCPClient)`
  — Spins up an `ARCPServer` on a `MemoryTransport`, connects an
  `ARCPClient`, returns both. Auth pre-wired with a static bearer
  token. Used by every example except `Stdio` and the host adapters.
- `func connectClient(url: URL, token: String) async throws -> ARCPClient`
  — For the host-integration examples; resolves the `wss://` URL from
  `ARCP_DEMO_URL` if set, else `127.0.0.1` on a port the example
  binds itself.
- `func expect<T: Equatable & Sendable>(_ actual: T, equals expected: T, file: StaticString = #file, line: UInt = #line)`
  — Throws `ExampleHarnessError.assertion` on mismatch; the example's
  top-level `Task` catches it and calls `fail(_:)`.
- `func expectEvent(_ stream: AsyncThrowingStream<JobEvent, Error>, kind: JobEvent.Kind, within: Duration) async throws -> JobEvent`
  — Pulls events with a `ContinuousClock`-based timeout; eliminates
  `sleep`-driven races.
- `func succeed(_ message: String = "ok") -> Never`
  — Prints `OK: <message>` to stdout, `exit(0)`.
- `func fail(_ message: String) -> Never`
  — Prints `FAIL: <message>` to stderr, `exit(1)`.

Visibility: declared `internal` to its target, with `package`-level
visibility into example targets via `dependencies: ["ExampleHarness"]`.
**Not** part of the public SDK; no DocC catalog; not exported via the
`ARCP` umbrella product.

The harness is the reason each `Server.swift`/`Client.swift` should
stay under ~80 lines. If an example needs to invent a helper, it goes
in the harness, not local stubs.

## 4. CI runner

The smoke script (`scripts/run-samples.sh`, invoked by the CI matrix
defined in `07-tests.md`):

```sh
set -euo pipefail
swift build --target ARCP
for sample in Samples/*/; do
  name=$(basename "$sample")
  echo "--- $name ---"
  timeout 60 swift run "$name" || { echo "FAIL: $name"; exit 1; }
done
```

Per-example runtime budget:

| Bucket           | Examples                                                                                       | Expected wall time |
| ---------------- | ---------------------------------------------------------------------------------------------- | ------------------ |
| Fast (≤ 2 s)     | `SubmitAndStream`, `Delegate`, `IdempotentRetry`, `LeaseViolation`, `VendorExtensions`, `CustomAuth`, `ListJobs`, `AgentVersions`, `Progress`, `ResultChunk` | ≤ 2 s each         |
| Medium (≤ 5 s)   | `Resume`, `Subscribe`, `AckBackpressure`, `LeaseExpiresAt`, `CostBudget`, `Stdio`, `OtelTracing` | ≤ 5 s each         |
| Long (≤ 30 s)    | `Cancel`, `Heartbeat`                                                                          | ≤ 30 s each        |
| Host (≤ 10 s)    | `Vapor`, `Hummingbird`, `NIO`                                                                  | ≤ 10 s each        |

`Cancel/` is long because the spec mandates a 30 s grace window
(§7.4); the example does NOT shorten it via configuration — it
verifies the grace is observed. `Heartbeat/` runs for two heartbeat
intervals (≥ 2 × interval) so that `heartbeat_lost` would actually
fire if the timer were broken. Both target the upper bound; the
shell `timeout 60` per example is the hard ceiling.

Total smoke-set wall time: budget ≤ 4 minutes serial; CI parallelizes
via `xargs -P 4` on the matrix runners that have ≥ 4 cores.

## 5. Out of scope — no example for

Per `BOOTSTRAP.md` non-goals and `01-spec-delta.md` §1, the SDK does
not implement these surfaces, so no example is planned:

- **Job pause / unpause.** Not in v1.0/v1.1 wire surface. The current
  Swift SDK's `JobState.paused/blocked` (audit §1.7.3) goes away with
  the v1.0 migration.
- **Job priority.** No `priority` field in §5.1 envelopes. The
  current SDK's envelope `priority` field (audit §1.5.1) is removed.
- **Federation / cross-runtime relay.** Not in scope of v1.0 or v1.1;
  `Heartbeats/` in the existing samples (`Samples/README.md`) covered
  worker federation, which is out of spec.
- **Streaming token surface for LLM tokens.** `kind: "thought"` event
  bodies are opaque strings; the SDK does not model a token stream
  type. The current `Reasoning-Streams/` sample is replaced by
  `Progress/` + `ResultChunk/`, which cover the two real streaming
  shapes.
- **Two-party permission challenge.** Out of spec for v1.1; the
  current `Permission-Challenge/` sample is dropped without
  replacement.
- **MCP fronting.** Out of spec; the current `MCP/` sample is dropped.
- **Lease revocation mid-flight.** v1.1 leases are immutable (§9.1);
  expiry (`LEASE_EXPIRED`) is the only termination mode. The current
  `Lease-Revocation/` sample is dropped — `LeaseExpiresAt/` covers
  the spec-supported case.
- **Capability negotiation as a user-facing dance.** §6.2 negotiation
  is implicit in every example (each one declares the features it
  uses via `ARCPClientOptions.features`). No standalone example —
  it would not show off a Swift idiom distinct from any feature
  example.

## 6. Differences from TS

Cases where Swift's example differs structurally rather than just
syntactically:

- **`bun/` → dropped.** Bun is a runtime swap of `ws` for a built-in
  WebSocket. Swift has no equivalent — `swift-nio` is the
  framework-free analogue, already covered by `NIO/`. Inventing a
  "BunEquivalent" target would duplicate `NIO/`.
- **`tracing/` SDK shape.** TS uses `@opentelemetry/sdk-node` with
  `BatchSpanProcessor` + `ConsoleSpanExporter`. Swift uses
  `swift-distributed-tracing` (the protocol) + `swift-otel` (per
  `03-libraries.md`), which exposes a different bootstrap surface
  (`OTel.Tracer` + `OTel.Configuration`). Wire-level expectations
  (`extensions["x-vendor.opentelemetry.tracecontext"]`, span
  attribute names) are identical.
- **`stdio/` runs as one process, not two.** TS `stdio/` already
  does this (`client.ts` spawns the runtime as a child). Swift
  matches via `Foundation.Process`. The one structural difference is
  that Swift `Process` requires explicit
  `standardInput`/`standardOutput` `Pipe()` wiring; the harness
  hides this behind a `try await Stdio.spawnAndConnect(serverPath:)`
  helper.
- **`subscribe/` uses two clients, not two terminals.** TS spins two
  `node` processes in the same example dir. Swift's
  `Samples/Subscribe/` has `ClientA.swift` and `ClientB.swift`, both
  driven by the single example's `@main` entry — both clients run as
  `async let` tasks on `MemoryTransport`, terminated by `succeed()`
  when both have observed the expected events. (This deviates from
  the "real transport, two processes" rule TS examples follow; the
  audit §6 noted CI flakiness from two-process tests, and
  `MemoryTransport` is the spec-sanctioned alternate per §4.3.)
- **`custom-auth/` uses `CryptoKit`, not `node:crypto`.** Same HMAC
  algorithm (SHA-256); the Swift example uses
  `HMAC<SHA256>.authenticationCode(...)`, available on macOS 10.15+
  and Linux via `swift-crypto` (per `03-libraries.md`).
- **`express/`, `fastify/` → `Vapor/`, `Hummingbird/`.** TS picks two
  WS-friendly Node HTTP frameworks; Swift picks the two production
  Swift-on-server HTTP frameworks. The demonstration is the same:
  "ARCP shares a port with the host's regular routes; DNS-rebind
  protection lives in the upgrade adapter."

The 22-example set is the steady state. If a v1.2 adds new features,
new rows go in §1; nothing in this layout (single Package, harness
target, exit-code contract, smoke script) needs to change.
