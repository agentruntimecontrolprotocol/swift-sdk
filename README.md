<h3 align="center">ARCP Swift SDK</h3>

<p align="center"><strong>Swift SDK for the Agent Runtime Control Protocol (ARCP) — submit, observe, and control long-running agent jobs from Swift.</strong></p>

<p align="center">
  <a href="https://swiftpackageindex.com/agentruntimecontrolprotocol/swift-sdk"><img alt="Swift Package Index" src="https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fagentruntimecontrolprotocol%2Fswift-sdk%2Fbadge%3Ftype%3Dswift-versions"></a>
  <a href="https://swiftpackageindex.com/agentruntimecontrolprotocol/swift-sdk"><img alt="Platforms" src="https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fagentruntimecontrolprotocol%2Fswift-sdk%2Fbadge%3Ftype%3Dplatforms"></a>
  <a href="https://github.com/agentruntimecontrolprotocol/swift-sdk/actions/workflows/test.yml"><img alt="CI" src="https://github.com/agentruntimecontrolprotocol/swift-sdk/actions/workflows/test.yml/badge.svg"></a>
  <a href="https://github.com/agentruntimecontrolprotocol/spec/blob/main/docs/draft-arcp-1.1.md"><img alt="ARCP" src="https://img.shields.io/badge/ARCP-v1.1%20draft-blue"></a>
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-Apache--2.0-lightgrey"></a>
  <a href="https://coderabbit.ai"><img alt="CodeRabbit" src="https://img.shields.io/coderabbit/prs/github/agentruntimecontrolprotocol/swift-sdk?utm_source=oss&utm_medium=github&utm_campaign=agentruntimecontrolprotocol/swift-sdk&labelColor=171717&color=FF570A&label=CodeRabbit+Reviews"></a>
</p>

<p align="center">
  <a href="https://github.com/agentruntimecontrolprotocol/spec/blob/main/docs/draft-arcp-1.1.md">Specification</a> ·
  <a href="#concepts">Concepts</a> ·
  <a href="#installation">Install</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="docs/">Guides</a> ·
  <a href="https://swiftpackageindex.com/agentruntimecontrolprotocol/swift-sdk/main/documentation/arcp">API reference</a>
</p>

---

The `ARCP` Swift package is the Swift reference implementation of [ARCP](https://github.com/agentruntimecontrolprotocol/spec/blob/main/docs/draft-arcp-1.1.md), the Agent Runtime Control Protocol. It covers both sides of the wire — `ARCPClient` for submitting and observing jobs, `ARCPRuntime` for hosting agents through a `ToolHandler` / `JobContext` pair — so either side can talk to any conformant peer in any language without hand-rolling the envelope, sequencing, or lease enforcement.

ARCP itself is a transport-agnostic wire protocol for long-running AI agent jobs. It owns the parts of agent infrastructure that don't change between products — sessions, durable event streams, capability leases, budgets, resume — and stays out of the parts that do. ARCP wraps the agent function; it does not define how agents are built, how tools are exposed (that's MCP), or how telemetry is exported (that's OpenTelemetry).

## Installation

Requires Swift 6.1 or later and macOS 14+. The SDK ships as a single Swift Package Manager package named `ARCP` with one executable product, `arcp`, for the bundled CLI. Add the dependency to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/agentruntimecontrolprotocol/swift-sdk.git", from: "1.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "ARCP", package: "swift-sdk"),
    ]),
]
```

## Quick start

Connect to a runtime, submit a job, stream its events to completion:

```swift
import ARCP
import NIOPosix

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let transport = try await WebSocketClient.connect(
    url: "wss://runtime.example.com/arcp",
    eventLoopGroup: group
)

let client = try await ARCPClient.open(
    transport: transport,
    auth: AuthBlock(scheme: .bearer, token: ProcessInfo.processInfo.environment["ARCP_TOKEN"]),
    client: IdentityBlock(kind: "quickstart", version: "1.0.0"),
    capabilities: Capabilities(streaming: true, durableJobs: true, subscriptions: true)
)

let result = try await client.invoke(
    tool: "data-analyzer",
    arguments: .object(["dataset": .string("s3://example/sales.csv")])
)

switch result.outcome {
case .completed(let payload):
    print("final:", payload.result ?? payload.summary ?? .null)
case .failed(let error):
    print("failed [\(error.code.rawValue)]:", error.message)
case .cancelled(let payload):
    print("cancelled:", payload.reason)
}

await client.close()
try await group.shutdownGracefully()
```

This is the whole shape of the SDK: open a session, submit work, consume an ordered event stream, get a terminal result or error. Everything below is detail on those four moves.

## Concepts

ARCP organizes everything around four concerns — **identity**, **durability**, **authority**, and **observability** — expressed through five core objects:

- **Session** — a connection between a client and a runtime. A session carries identity (a bearer token), negotiates a feature set in a `session.open`/`session.accepted` handshake, and is *resumable*: if the transport drops, you reconnect with a resume token and the runtime replays buffered events. Jobs outlive the session that started them. See [§6](https://github.com/agentruntimecontrolprotocol/spec/blob/main/docs/draft-arcp-1.1.md).
- **Job** — one unit of agent work submitted into a session. A job has an identity, an optional idempotency key, a resolved agent version, and a lifecycle that ends in exactly one terminal state: `success`, `error`, `cancelled`, or `timed_out`. See [§7](https://github.com/agentruntimecontrolprotocol/spec/blob/main/docs/draft-arcp-1.1.md).
- **Event** — the ordered, session-scoped stream a job emits: logs, thoughts, tool calls and results, status, metrics, artifact references, progress, and streamed result chunks. Events carry strictly monotonic sequence numbers so the stream survives reconnects gap-free. See [§8](https://github.com/agentruntimecontrolprotocol/spec/blob/main/docs/draft-arcp-1.1.md).
- **Lease** — the authority a job runs under, expressed as capability grants (`fs.read`, `fs.write`, `net.fetch`, `tool.call`, `agent.delegate`, `cost.budget`, `model.use`). The runtime enforces the lease at every operation boundary; a job can never act outside it. Leases may carry a budget and an expiry, and may be subset and handed to sub-agents via delegation. See [§9](https://github.com/agentruntimecontrolprotocol/spec/blob/main/docs/draft-arcp-1.1.md).
- **Subscription** — read-only attachment to a job started elsewhere (e.g. a dashboard watching a job a CLI submitted). A subscriber observes the live event stream but cannot cancel or mutate the job. Distinct from *resume*, which continues the original session and carries cancel authority. See [§7.6](https://github.com/agentruntimecontrolprotocol/spec/blob/main/docs/draft-arcp-1.1.md).

The SDK models each of these as first-class objects; the rest of this README shows how.

## Guides

### Sessions and resume

Open a session, negotiate features, and reconnect transparently after a transport drop using the resume token — jobs keep running server-side while you're gone.

```swift
import ARCP

let client = try await ARCPClient.open(
    transport: transport,
    auth: AuthBlock(scheme: .bearer, token: token),
    client: IdentityBlock(kind: "resumable", version: "1.0.0"),
    capabilities: Capabilities(streaming: true, durableJobs: true)
)

// Track the last envelope we saw so we can resume gap-free.
var lastSeen: MessageId?
let drainer = Task {
    for await envelope in client.unhandled {
        lastSeen = envelope.id
    }
}

// ... transport drops; reconnect over a fresh transport ...

let resumed = try await ARCPClient.open(
    transport: try await WebSocketClient.connect(url: url, eventLoopGroup: group),
    auth: AuthBlock(scheme: .bearer, token: token),
    client: IdentityBlock(kind: "resumable", version: "1.0.0"),
    capabilities: Capabilities(streaming: true, durableJobs: true)
)
try await resumed.send(
    Envelope(
        sessionId: resumed.info.sessionId, jobId: jobId,
        payload: .resume(ResumePayload(afterMessageId: lastSeen, includeOpenStreams: true))
    )
)
// The runtime replays every envelope with id > lastSeen, then resumes live streaming.
drainer.cancel()
```

### Submitting jobs

Submit a job with an agent (optionally version-pinned as `name@version`), an input, and an optional lease request, idempotency key, and runtime limit.

```swift
let invocation = try await client.invoke(
    tool: "weekly-report@2.1.0",
    arguments: .object(["week": .string("2026-W19")]),
    costBudget: .from(["USD": 1.00]),
    leaseConstraints: LeaseConstraints(expiresAt: Date().addingTimeInterval(60)),
    idempotencyKey: IdempotencyKey("weekly-report-2026-W19")
)

print("job_id =", invocation.jobId?.rawValue ?? "(pending)")
print("outcome =", invocation.outcome)
```

### Consuming events

Iterate the ordered event stream — `log`, `thought`, `tool_call`, `tool_result`, `status`, `metric`, `artifact_ref`, `progress`, `result_chunk` — and optionally acknowledge progress so the runtime can release buffered events early.

```swift
let invocation = try await client.invoke(
    tool: "summarizer",
    arguments: .object(["text": .string(corpus)])
)

// Stream structured progress while the job runs.
let progressTask = Task {
    for await progress in invocation.progress {
        let percent = progress.percent.map { String(format: "%.0f%%", $0) } ?? "?"
        print("progress \(percent) — \(progress.message ?? "")")
    }
}

// Every event the client didn't consume internally surfaces here in order.
for await envelope in await client.unhandled {
    switch envelope.payload {
    case .log(let log):
        print("[\(log.level)] \(log.message)")
    case .metric(let m):
        print("metric \(m.name)=\(m.value)\(m.unit.map { " \($0)" } ?? "")")
    case .jobCompleted, .jobFailed, .jobCancelled:
        break
    default:
        continue
    }
}
progressTask.cancel()
```

### Leases and budgets

Request capabilities, a budget, and an expiry; read budget-remaining metrics as they arrive; handle the runtime's enforcement decisions.

```swift
let invocation = try await client.invoke(
    tool: "web-research",
    arguments: .object(["iterations": .int(8), "perCallUSD": .double(0.3)]),
    costBudget: .from(["USD": 1.00]),
    leaseConstraints: LeaseConstraints(expiresAt: Date().addingTimeInterval(600))
)

// Surface cost.budget.remaining metrics as they arrive.
let watcher = Task {
    for await env in await client.unhandled {
        if case .metric(let m) = env.payload, m.name == "cost.budget.remaining" {
            let unit = m.unit ?? ""
            print(String(format: "budget remaining: %.2f %@", m.value, unit))
        }
    }
}

if case .failed(let error) = invocation.outcome {
    // BUDGET_EXHAUSTED and LEASE_EXPIRED are never retryable.
    print("job ended [\(error.code.rawValue)]: \(error.message)")
}
watcher.cancel()
```

### Subscribing to jobs

Attach read-only to a job submitted elsewhere and observe its live stream (with optional history replay) without cancel authority.

```swift
let observer = try await ARCPClient.open(
    transport: try await WebSocketClient.connect(url: url, eventLoopGroup: group),
    auth: AuthBlock(scheme: .bearer, token: token),
    client: IdentityBlock(kind: "dashboard", version: "1.0.0"),
    capabilities: Capabilities(subscriptions: true)
)

let filter = SubscriptionFilter(jobIds: [jobId])
try await observer.send(
    Envelope(
        sessionId: observer.info.sessionId,
        payload: .subscribe(
            SubscribePayload(filter: filter, since: SubscriptionSince(afterMessageId: nil))
        )
    )
)

for await envelope in await observer.unhandled {
    if case .subscribeEvent(let payload) = envelope.payload {
        print("event:", payload.event)
    }
}
```

### Error handling

Catch the typed error taxonomy and respect the `retryable` flag — `LEASE_EXPIRED` and `BUDGET_EXHAUSTED` are never retryable; a naive retry fails identically.

```swift
do {
    let invocation = try await client.invoke(tool: "flaky", arguments: .null)
    if case .failed(let error) = invocation.outcome {
        switch error.code {
        case .leaseExpired, .budgetExhausted:
            throw ARCPError.failedPrecondition(detail: "renew lease/budget and resubmit")
        default:
            if error.retryable == true {
                // safe to retry with backoff (e.g. internal, unavailable, deadlineExceeded)
            }
        }
    }
} catch let error as ARCPError {
    if error.isRetryable {
        // backoff and retry
    }
    throw error
}
```

## Feature support

ARCP features this SDK negotiates during the `session.open`/`session.accepted` handshake:

| Feature flag | Status |
|---|---|
| `heartbeat` | Supported |
| `ack` | Planned |
| `list_jobs` | Supported |
| `subscribe` | Supported |
| `lease_expires_at` | Supported |
| `cost.budget` | Supported |
| `model.use` | Supported |
| `provisioned_credentials` | Supported |
| `progress` | Supported |
| `result_chunk` | Supported |
| `agent_versions` | Supported |

## Transport

ARCP is transport-agnostic. This SDK ships a `WebSocketTransport` (client-side, built on `WebSocketKit` / SwiftNIO), a `StdioTransport` (NDJSON framing over stdin/stdout for in-process child runtimes), and a `MemoryTransport` (in-process pair for tests and samples). WebSocket is the default for networked runtimes; stdio is used for in-process child runtimes. Select one by constructing the corresponding `Transport` — `WebSocketClient.connect(url:eventLoopGroup:)`, `StdioTransport(inbound:outbound:)`, or `MemoryTransport.makePair()` — and passing it to `ARCPClient.open(transport:auth:client:capabilities:)`.

## API reference

Full API reference — every type, method, and event payload — is in [`docs/`](docs/) and at <https://swiftpackageindex.com/agentruntimecontrolprotocol/swift-sdk/main/documentation/arcp>.

## Versioning and compatibility

This SDK speaks **ARCP v1.1 (draft)**. The SDK follows semantic versioning independently of the protocol; the negotiated runtime version is available on `client.info.runtimeIdentity.version`. A runtime advertising a different ARCP MAJOR is not guaranteed compatible. Feature mismatches degrade gracefully: the effective feature set is the intersection of what the client and runtime advertise, and the SDK will not use a feature outside it.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Protocol questions and proposed changes belong in the [spec repository](https://github.com/agentruntimecontrolprotocol/spec); SDK bugs and feature requests belong here.

## License

Apache-2.0 — see [`LICENSE`](LICENSE).
