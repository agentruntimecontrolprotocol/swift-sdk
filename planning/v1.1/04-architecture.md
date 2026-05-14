# 04 — Architecture & idioms

**Inputs:** [`01-spec-delta.md`](01-spec-delta.md), [`02-current-audit.md`](02-current-audit.md),
spec [`../../../spec/docs/draft-arcp-02.1.md`](../../../spec/docs/draft-arcp-02.1.md),
TS layout under [`../../../typescript-sdk/packages/`](../../../typescript-sdk/packages/).

This is the target layout the milestones in `10-synthesis.md` will land
against. It assumes the audit's verdict: v1.0 wire alignment is the
foundation; v1.1 features are additive PRs on that foundation.

## 1. SwiftPM target layout

Four library targets + one umbrella, mirroring TS
[`@arcp/{core,client,runtime,sdk}`](../../../typescript-sdk/packages/).

| Target        | Depends on               | Public API surface                                        | Why it exists                                                                                                                                                                       |
| ------------- | ------------------------ | --------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ARCPCore`    | `Foundation` only        | Envelope, `Message`, `JobEventBody`, `Lease`, `Pattern`, `Budget`, `Capabilities`, `Feature`, `ARCPError`, IDs, `Transport` protocol, `MemoryTransport`, `StdioTransport`. | Importable by both client and runtime without dragging in WebSocket-server deps. Mirrors `@arcp/core`. `Foundation`-only keeps Linux + iOS build cheap. |
| `ARCPClient`  | `ARCPCore`, `swift-log`  | `actor ARCPClient`, `Job` handle, `JobSubscription`, `JobEventStream`. | Mirrors `@arcp/client` ([`packages/client/package.json:44`](../../../typescript-sdk/packages/client/package.json#L44)). Holds connection-side state.        |
| `ARCPRuntime` | `ARCPCore`, `swift-log`  | `actor ARCPServer`, `protocol Agent`, `JobContext`, `LeaseEvaluator`, in-memory resume buffer. | Mirrors `@arcp/runtime`. The job dispatch tree (job actor per running job) lives here.                                                                  |
| `ARCP`        | `ARCPCore`, `ARCPClient`, `ARCPRuntime` | Re-exports the three. No new symbols.                                | Mirrors `@arcp/sdk` ([`packages/sdk/package.json:69`](../../../typescript-sdk/packages/sdk/package.json#L69)) for callers that want everything.            |
| `ARCPWebSocketClient` | `ARCPCore` + `URLSessionWebSocketTask` (Apple) / `websocket-kit` (Linux fallback per `03-libraries.md`) | `WebSocketTransport` conforming to `Transport`. | Keeps Core free of platform-specific WS deps. The audit ([§2.2](02-current-audit.md)) flagged URLSession on Linux as risky; isolating to its own target makes the dep-swap a one-line `Package.swift` change. |
| `ARCPVapor`, `ARCPHummingbird`, `ARCPOTel` | host-specific            | Per [`05-middleware.md`](05-middleware.md).                            | Server middleware lives outside `ARCPRuntime` so the runtime stays framework-free.                                                                       |

**Merges considered and rejected.** Folding `ARCPClient` and
`ARCPRuntime` together (a single `ARCP` target like today's
[`Package.swift`](../../Package.swift)) was the v0.x choice; it forces
a client-only embedder to ship runtime code, breaks the
public-surface boundary TS already enforces, and would make the
audit's "throwaway pieces" list bleed into the client target. Keep
them split.

**Splits considered and rejected.** Splitting `ARCPCore` into
`ARCPEnvelope` + `ARCPMessages` + `ARCPLease` (mirroring TS
sub-paths under `packages/core/src/`) adds three SwiftPM products
with no consumer that imports one but not the others. SwiftPM doesn't
make sub-product imports cheaper than module imports. Keep as one.

**`ARCPStoreSQLite`** is a separate opt-in target (per audit §2.1 verdict
on `SQLite.swift`). Default `ARCPRuntime` keeps the resume buffer in
memory; persistence is an additive product.

## 2. Type model

### 2.1 Envelope

```swift
public struct Envelope: Sendable, Hashable {
    public let arcp: String              // "1"
    public let id: MessageId             // ULID
    public let sessionId: SessionId?     // §5.1 required post-welcome
    public let jobId: JobId?
    public let eventSeq: Int?            // §5.1 REQUIRED on job.event/result/error
    public let traceId: TraceId?
    public let message: Message          // discriminator + payload
}

extension Envelope: Codable { /* manual init/encode — see below */ }
```

Manual `Codable`. `JSONDecoder` already ignores unknown top-level keys
([Apple Foundation docs](https://developer.apple.com/documentation/foundation/jsondecoder)),
satisfying §5.1's passthrough rule by default; the manual conformance
exists because the `type` string must dispatch to the right
`Message` case at decode and reverse at encode — synthesized `Codable`
on an `enum` with associated values uses a different on-wire shape
(Swift's `keyedBy:` synthesis emits `{ "case_name": { ... } }`,
not the `{ "type": "...", "payload": {...} }` ARCP shape).

The `eventSeq` field is `Int?` rather than `UInt64`; spec §8.3 makes
it strictly positive but interop with `JSONDecoder`'s number bridging
across Linux Foundation is more uniform on `Int`. Range-check at
decode; max is `Int.max` on 64-bit (the only supported platforms per
[`03-libraries.md`](03-libraries.md)).

### 2.2 Message taxonomy

```swift
public enum Message: Sendable, Hashable {
    // §6 session control
    case sessionHello(SessionHelloPayload)
    case sessionWelcome(SessionWelcomePayload)
    case sessionBye(SessionByePayload)
    case sessionError(SessionErrorPayload)
    case sessionPing(SessionPingPayload)         // §6.4
    case sessionPong(SessionPongPayload)         // §6.4
    case sessionAck(SessionAckPayload)           // §6.5
    case sessionListJobs(SessionListJobsPayload) // §6.6
    case sessionJobs(SessionJobsPayload)         // §6.6 response

    // §7 jobs
    case jobSubmit(JobSubmitPayload)
    case jobAccepted(JobAcceptedPayload)
    case jobEvent(JobEventEnvelope)              // §8 carrier
    case jobResult(JobResultPayload)
    case jobError(JobErrorPayload)
    case jobCancel(JobCancelPayload)

    // §7.6 subscribe
    case jobSubscribe(JobSubscribePayload)
    case jobSubscribed(JobSubscribedPayload)
    case jobUnsubscribe(JobUnsubscribePayload)

    public var wireType: String { /* "session.hello" etc. */ }
}
```

Single closed enum, one case per spec `type` string. Discriminator is
the `type` field on the envelope (§5.1); the manual `Codable` on
`Envelope` reads `type` first, then decodes the payload into the
matching case's associated value. v1.0 wire types appear here too;
the v1.1-only types (`sessionPing`, `sessionPong`, `sessionAck`,
`sessionListJobs`, `sessionJobs`, `jobSubscribe`, `jobSubscribed`,
`jobUnsubscribe`) are reachable only when the matching `Feature` is
in the negotiated set; the client gates emission, the server gates
reception (`INVALID_REQUEST` if a peer uses a non-negotiated feature
type per spec §6.2).

A vendor-extension fallback (`case xVendor(String, JSONValue)`) is
not added; §5.1 says unknown top-level fields are ignored, but
unknown `type` values are an envelope-level error (`INVALID_REQUEST`
per §12). The decoder throws `ARCPError.invalidRequest` on unknown
`type`; this is the symmetric thing to TS
[`packages/core/src/envelope.ts`](../../../typescript-sdk/packages/core/src/envelope.ts)
behavior.

### 2.3 Job events

```swift
public struct JobEventEnvelope: Sendable, Hashable, Codable {
    public let kind: JobEventKind  // RawRepresentable String
    public let ts: Date            // ISO-8601, see §2.10
    public let body: JobEventBody
}

public enum JobEventKind: String, Sendable, Hashable, Codable, CaseIterable {
    case log, thought, toolCall = "tool_call", toolResult = "tool_result",
         status, metric, artifactRef = "artifact_ref",
         delegate, progress, resultChunk = "result_chunk"
}

public enum JobEventBody: Sendable, Hashable {
    case log(level: LogLevel, message: String)
    case thought(text: String)
    case toolCall(tool: String, args: JSONValue, callId: String)
    case toolResult(callId: String, outcome: ToolOutcome)   // result|error
    case status(phase: String, message: String?)
    case metric(name: String, value: Decimal, unit: String?, dimensions: [String: JSONValue]?)
    case artifactRef(uri: String, contentType: String, byteSize: Int?, sha256: String?)
    case delegate(DelegatePayload)                          // §10
    case progress(current: Int, total: Int?, units: String?, message: String?)  // §8.2.1
    case resultChunk(ResultChunkBody)                       // §8.4
}

public struct ResultChunkBody: Sendable, Hashable, Codable {
    public let resultId: ResultId
    public let chunkSeq: Int
    public let data: ResultChunkData
    public let more: Bool
}

public enum ResultChunkData: Sendable, Hashable {
    case utf8(String)
    case base64(Data)
}
```

`JobEventBody` is a closed enum, not a `[String: Any]` blob; this
gives `for try await event in stream` the same exhaustiveness Swift
gives `switch` on `Result`. The `body` field of the wire envelope is
the associated value; manual `Codable` on `JobEventBody` reads
`kind` first.

`Decimal` for metric value (not `Double`): cost metrics flow through
this case (`name: "cost.inference"`), spec §9.6 requires decimal
precision on currency, mixing precision representations is a latent
rounding bug. Non-cost metrics pay the `Decimal` tax (microseconds of
allocation) for one source of truth.

`ResultChunkData`'s two-arm enum prevents §8.4's "encoding ∈ {utf8, base64}"
from being a runtime check on a `String` field. A caller cannot
construct a `.utf8(Data)` mistake; the type system rules it out.

### 2.4 Lease

```swift
public struct Lease: Sendable, Hashable {
    public let capabilities: [Capability: [Pattern]]   // §9.2
    public let constraints: LeaseConstraints?          // §9.5
    public let budget: Budget?                         // §9.6 initial
}

public struct LeaseConstraints: Sendable, Hashable, Codable {
    public let expiresAt: Date?
}

public enum Capability: Sendable, Hashable, RawRepresentable, Codable {
    case fsRead, fsWrite, netFetch, toolCall, agentDelegate, costBudget
    case xVendor(String)   // namespaces under `x-vendor.*`

    public init?(rawValue: String) { /* maps "fs.read" etc. */ }
    public var rawValue: String { /* inverse */ }
}

public struct Pattern: Sendable, Hashable {
    public let raw: String
    let compiled: CompiledGlob   // internal — built once on init
    public init(_ raw: String) throws  // throws .invalidRequest if grammar fails
}

public enum LeaseOp: Sendable {
    case fsRead(path: String), fsWrite(path: String)
    case netFetch(url: String), toolCall(name: String)
    case agentDelegate(name: String)
    case costSpend(currency: Currency, amount: Decimal)
}

public struct LeaseEvaluator: Sendable {
    public func authorize(
        _ op: LeaseOp,
        against lease: Lease,
        now: Date,
        budgetRemaining: [Currency: Decimal]?
    ) -> Result<Void, ARCPError>
}
```

`Capability` is `RawRepresentable` rather than a bare `String` enum
because Swift case names cannot contain `.`; the wire form is
`fs.read`, the Swift form is `.fsRead`. The `xVendor(String)` case
holds any namespace prefixed with `x-` per §9.2.

`Pattern` compiles its glob on construction — `*` (single path
segment) and `**` (zero+ segments) per §9.2. Doing it eagerly turns
"this lease has a typo'd pattern" into a submission-time error rather
than a per-op surprise. The compiled form is a private struct, not
exposed in the public surface.

`LeaseEvaluator.authorize` returns `Result<Void, ARCPError>` rather
than `throws` because this is one of the few seams where the error
**is the value**: the runtime calls this on every authority-bearing
op and the caller routes the categorized failure into either a
`tool_result` body or a `job.error` envelope per §9.6. `throws` would
force a `do/catch` per call site to extract the same information.

### 2.5 Feature enum

```swift
public enum Feature: String, Sendable, Hashable, CaseIterable, Codable {
    case heartbeat        = "heartbeat"
    case ack              = "ack"
    case listJobs         = "list_jobs"
    case subscribe        = "subscribe"
    case leaseExpiresAt   = "lease_expires_at"
    case costBudget       = "cost.budget"
    case progress         = "progress"
    case resultChunk      = "result_chunk"
    case agentVersions    = "agent_versions"
}
```

Closed, exhaustive, raw-value-mapped to the wire string. The
intersection logic (`Set<Feature>` on both sides, in-process) drops
unknown wire features per spec §6.2 implicitly: a wire feature outside
the case set does not decode into the `Set<Feature>` value. This is
exactly the v1.0/v1.1 intersection rule, expressed as type narrowing.

### 2.6 Errors

```swift
public enum ARCPError: Error, Sendable, Hashable {
    // v1.0 — 12 codes
    case permissionDenied(capability: Capability, target: String)
    case leaseSubsetViolation(detail: String)
    case jobNotFound(jobId: JobId)
    case duplicateKey(key: String, existingJobId: JobId)
    case agentNotAvailable(name: String)
    case cancelled(reason: String?)
    case timeout(maxRuntimeSec: Int)
    case resumeWindowExpired(lastSeenSeq: Int)
    case heartbeatLost(missedIntervals: Int)
    case invalidRequest(detail: String)
    case unauthenticated(detail: String)
    case `internal`(detail: String)
    // v1.1 — 3 codes
    case leaseExpired(at: Date)
    case budgetExhausted(currency: Currency, attempted: Decimal)
    case agentVersionNotAvailable(name: String, version: String, available: [String])

    public var wireCode: String { /* "PERMISSION_DENIED" etc. */ }
    public var retryable: Bool {
        switch self {
        case .internal: return true
        default: return false  // spec §12: only INTERNAL_ERROR is retryable
        }
    }
}
```

Closed 15-case enum; computed `retryable` per spec §12, not stored
(stored would drift from the case). Each case carries the structured
context the spec requires for client-side handling (e.g.,
`agentVersionNotAvailable` carries `available: [String]` so a client
can fall back without a second list_jobs round-trip). `Sendable`
because all associated values are value types of Sendable members.

### 2.7 IDs

```swift
public struct MessageId: Sendable, Hashable, Codable, RawRepresentable { public let rawValue: String }
public struct SessionId: Sendable, Hashable, Codable, RawRepresentable { public let rawValue: String }
public struct JobId:     Sendable, Hashable, Codable, RawRepresentable { public let rawValue: String }
public struct ResultId:  Sendable, Hashable, Codable, RawRepresentable { public let rawValue: String }
public struct TraceId:   Sendable, Hashable, Codable, RawRepresentable { public let rawValue: String }

public struct ResumeToken: Sendable, Hashable, Codable {
    // ≥128 bits entropy per spec §6.2; opaque to clients.
    public let rawValue: String
    public init(generating rng: inout SystemRandomNumberGenerator) { /* 16 random bytes, base64url */ }
}

public struct Currency: Sendable, Hashable, Codable, RawRepresentable {
    public let rawValue: String
    public init?(rawValue: String)  // validates `[A-Za-z][A-Za-z0-9_-]*`
    public static let usd = Currency(rawValue: "USD")!
    public static let eur = Currency(rawValue: "EUR")!
    public static let credits = Currency(rawValue: "credits")!
}
```

Typed newtypes prevent cross-id misuse at compile time — a function
that takes `SessionId` cannot be handed a `JobId` even though both
wrap `String`. This pattern survives from the existing
[`Ids/Ids.swift`](../../Sources/ARCP/Ids/Ids.swift) per audit §4.
`ResumeToken` is its own type because its lifecycle differs from a
`MessageId` (rotates on each welcome per §6.2; never appears in URLs
or logs; constructed only by the runtime).

`Currency` is a String wrapper rather than a closed enum because
§9.6 grammar admits runtime-defined currencies (`currency ::= "USD"
| "EUR" | "credits" | <runtime-defined>`) — a closed enum would
break forward compat. Validation runs on init; arithmetic across
currencies is meaningless and `Budget` flags it (see below).

### 2.8 Budget

```swift
public struct Budget: Sendable, Hashable, Codable {
    public private(set) var remaining: [Currency: Decimal]

    /// Returns false if the decrement would leave the counter below zero.
    /// Caller raises `.budgetExhausted` on false. Mutates in place on true.
    public mutating func decrement(_ currency: Currency, by amount: Decimal) -> Bool

    public func isExhausted(_ currency: Currency) -> Bool
}
```

`Decimal` (not `Double`) per audit §0 and spec §9.6: `Double` corrupts
cents through binary-fraction rounding. `Budget` is a value type;
the runtime holds it inside the per-job actor so mutation is actor-
isolated; reads from `JobContext.budget` return a snapshot copy
(value semantics make this free).

`decrement` returns `Bool` rather than `throws`: this is hot-path code
running on every authority-bearing op; the caller (`LeaseEvaluator`)
folds the false return into a `Result.failure(.budgetExhausted(...))`
without a `try`/`catch` allocation.

### 2.9 Capabilities (negotiation)

```swift
public struct Capabilities: Sendable, Hashable, Codable {
    public let encodings: [String]          // §6.2 "json"
    public let features: Set<Feature>        // §6.2 v1.1 addition
    public let agents: [AgentRecord]?        // §6.2 enriched in v1.1
}

public enum AgentRecord: Sendable, Hashable {
    case flat(name: String)                 // v1.0 shape
    case rich(name: String, versions: [String], default: String?)  // §6.2 v1.1
}
```

`AgentRecord` is a sum because the wire allows both shapes
unconditionally (spec §6.2 backward-compat). The custom `Codable`
tries `rich` first (presence of the `versions` key), falls back to
`flat`. This is the exact pattern TS
[`packages/runtime/src/server.ts`](../../../typescript-sdk/packages/runtime/src/server.ts)
applies in `makeNegotiatedCapabilities`. A `Set<Feature>` ignores
unknown wire features at decode (per §2.5 above), which is precisely
the v1.1 intersection rule.

### 2.10 Timestamps

`Date` for wire serialization only (`ISO 8601 with Z` per §9.5). All
elapsed-time decisions — heartbeat interval, ack debounce, lease
expiry sweep — use `ContinuousClock` (`SuspendingClock` if the
session actor is willing to suspend on system sleep). Spec §14 calls
for "monotonic, NTP-disciplined clock"; `Date` jumps backward on NTP
adjustment, so reading `Date().timeIntervalSince(other)` for a
heartbeat decision is a latent bug. The runtime stores the lease's
`expires_at` as a `Date` (wire) plus a `ContinuousClock.Instant`
(local elapsed-deadline) computed at acceptance.

## 3. Concurrency model

### 3.1 Actors

| Actor                          | Owns                                                                                            | Module        |
| ------------------------------ | ----------------------------------------------------------------------------------------------- | ------------- |
| `actor ARCPClient`             | transport handle, pending one-shot continuations (`[MessageId: Continuation]`), live job subscriptions, negotiated `Set<Feature>` (immutable post-welcome → `let`). | `ARCPClient`  |
| `actor ARCPServer`             | bound transports (one per accepted connection), agent registry (`[String: [Version: any Agent]]`), session table. | `ARCPRuntime` |
| `actor SessionActor` (internal) | per-session state: ack cursor, heartbeat timer, monotonic `event_seq`, resume buffer (in-memory ring), subscriber table for `job.subscribe`. | `ARCPRuntime` |
| `actor JobActor` (internal)    | per-job state: lease, `Budget`, `JobState`, agent task, `JobContext` bridge.                    | `ARCPRuntime` |
| `actor Mailbox<Element>`       | single-consumer buffered queue — surviving piece from [`Runtime/Mailbox.swift`](../../Sources/ARCP/Runtime/Mailbox.swift). | `ARCPCore`    |

One actor per running job (per `JobActor`) rather than a single
`JobManager` table-of-jobs actor (the current shape per
[`Runtime/JobManager.swift`](../../Sources/ARCP/Runtime/JobManager.swift)).
Per-job actors mean two jobs can emit events concurrently without
serializing on a runtime-wide lock; the session actor is the funnel
that imposes session-scoped `event_seq` monotonicity per §8.3, which
is a single increment per emission and cheap.

### 3.2 Async surface

Every public method is `async` if it can suspend; pure value-extracting
accessors are `nonisolated` properties on the actor (e.g.,
`var negotiatedFeatures: Set<Feature>` is `nonisolated` because the
`Set` is immutable after connect and held as `let`).

Stream-returning APIs return `AsyncThrowingStream<T, Error>`.
`AsyncStream` (non-throwing) is used only where the producer cannot
fail — currently nowhere in the public surface, because `transport.receive`
is modeled as failing if the transport drops.

### 3.3 Cancellation

Every `async` call with an unbounded wait wraps its continuation in
`withTaskCancellationHandler { ... } onCancel: { /* resume with .cancelled */ }`.
The pending-continuation tables on `ARCPClient` (surviving from
[`Client/ARCPClient.swift:15`](../../Sources/ARCP/Client/ARCPClient.swift#L15))
remove the cancelled entry's id on cancellation so a late wire
response doesn't double-resume. Long-running loops (the dispatcher,
the heartbeat ticker) check `Task.checkCancellation()` at the top of
each iteration.

### 3.4 AsyncThrowingStream lifecycle

The H-risk from audit §3 is `subscribe`. The contract:

```swift
public func subscribe(jobID: JobId) -> AsyncThrowingStream<JobEvent, Error> {
    AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1024)) { continuation in
        let subscriberId = SubscriberId.random()
        Task {
            await self.registerSubscriber(subscriberId, jobID: jobID, continuation: continuation)
        }
        continuation.onTermination = { [weak self] _ in
            // Fire-and-forget; the Task captures `self?` strongly inside.
            Task { [weak self] in
                await self?.unregisterSubscriber(subscriberId)
                try? await self?.sendUnsubscribe(jobID: jobID)
            }
        }
    }
}
```

`.onTermination` covers three cases per Swift evolution
[SE-0314](https://github.com/apple/swift-evolution/blob/main/proposals/0314-async-stream.md):
consumer drops the iterator (cancellation), consumer calls `return` /
breaks from `for try await`, the producer side calls
`continuation.finish()`. All three must:

1. Remove the subscriber entry from the runtime-side session actor.
2. Emit `job.unsubscribe` (spec §7.6) so the runtime can free its
   subscriber slot — best-effort; if the transport is already dead
   the send fails silently.

The `.bufferingNewest(1024)` policy bounds memory on a slow consumer
per audit §5; spec doesn't mandate a number but the TS SDK uses a
similar bound. Configurable on the client.

### 3.5 No-fly list

- No `@MainActor` anywhere in `ARCPCore`, `ARCPClient`, `ARCPRuntime`.
  UI integration is a consumer concern; the SDK doesn't presume a
  thread.
- No `DispatchSemaphore`, no `DispatchQueue` on any public surface.
  The only `dispatch_*` allowed is inside concrete transports (e.g.,
  `URLSessionWebSocketTask` callback bridging if needed) and only
  behind the `Transport` protocol boundary.
- No synchronous blocking I/O in `async` paths. `Transport.send` is
  `async throws`; no `transport.sendSync` exists.
- `final` only when reference identity matters. `Pattern` is a
  struct, not a `final class`; `Envelope` is a struct; the only
  classes are inside transport implementations where SwiftNIO /
  URLSession force them. Public surface uses no classes.

### 3.6 Sendable posture

| Type                | Sendable mechanism                                                                |
| ------------------- | --------------------------------------------------------------------------------- |
| `Envelope`, `Message`, `JobEventEnvelope`, `JobEventBody`, all payloads | Auto-derived; all members are Sendable value types.                              |
| `Lease`, `Pattern`, `Budget`, `Capabilities` | Auto-derived; `Pattern.compiled` is a Sendable value type.                       |
| `ARCPError`         | Auto-derived; all associated values are Sendable.                                |
| `Feature`, `Capability`, `Currency` | RawRepresentable String → trivially Sendable.                                    |
| `ARCPClient`, `ARCPServer`, `SessionActor`, `JobActor`, `Mailbox` | Sendable by actor isolation.                                                     |
| `protocol Transport` | Conformance requires `Sendable` (cannot be implemented otherwise).               |
| `protocol Agent`    | Same.                                                                            |
| `JobContext`        | Protocol; concrete impl is a Sendable struct holding `weak var` (or unowned) to `JobActor` via a `Sendable` proxy. |

No `@unchecked Sendable` on the public surface. The audit's one
existing instance (the ISO8601 cache in
[`Envelope.swift:191`](../../Sources/ARCP/Envelope/Envelope.swift#L191))
stays as `nonisolated(unsafe)` (configure-once, read-many — sound).

## 4. Public API sketch

### 4.1 `protocol Transport`

```swift
public protocol Transport: Sendable {
    func send(_ envelope: Envelope) async throws        // one frame
    var receive: AsyncStream<Envelope> { get }          // incoming frames
    func close() async                                  // idempotent
}
```

Surviving from [`Transport/Transport.swift`](../../Sources/ARCP/Transport/Transport.swift)
per audit §4. `Sendable` is mandatory because a `Transport` is
handed across actor boundaries (client actor sends, server actor
sends).

### 4.2 `protocol Agent`

```swift
public protocol Agent: Sendable {
    static var name: String { get }
    static var version: String { get }     // §7.5 — opaque

    func run(input: JSONValue, context: any JobContext) async throws -> JobOutcome
}

public protocol StreamedResultAgent: Agent {
    func runStreaming(input: JSONValue, context: any JobContext) async throws
}
```

Two-protocol design: a `StreamedResultAgent` emits chunks via
`context.streamResult()` and lets the runtime infer the result is
streamed (sets `result_id` on the terminal `job.result` per §8.4).
Bare `Agent` returns a `JobOutcome` (the inline form). The TS SDK
uses the same split in
[`packages/runtime/src/agent.ts`](../../../typescript-sdk/packages/runtime/src/agent.ts).
`Sendable` is mandatory; an `Agent` value is captured by the per-job
actor.

### 4.3 `actor ARCPClient`

```swift
public actor ARCPClient {
    public nonisolated let negotiatedFeatures: Set<Feature>

    public static func connect(
        transport: any Transport,
        auth: AuthBlock,
        clientFeatures: Set<Feature> = Feature.allClient
    ) async throws -> ARCPClient

    public func submit(
        agent: AgentRef,                    // name or name@version
        input: JSONValue,
        lease: LeaseRequest,
        constraints: LeaseConstraints? = nil,    // feature-gated: leaseExpiresAt
        budget: Budget? = nil,                   // feature-gated: costBudget
        idempotencyKey: String? = nil,
        maxRuntimeSec: Int? = nil
    ) async throws -> Job

    public func listJobs(filter: JobFilter, limit: Int, cursor: String?)
        async throws -> JobListPage                       // feature-gated: listJobs

    public func subscribe(jobID: JobId, fromEventSeq: Int? = nil, history: Bool = false)
        -> AsyncThrowingStream<JobEvent, Error>           // feature-gated: subscribe; returns JobSubscription on resolve

    public func ack(_ seq: Int) async throws              // feature-gated: ack

    public func bye(reason: String?) async throws         // §6.7
}
```

Feature-gating: `submit(... constraints:)` with a non-nil constraints
on a session that didn't negotiate `leaseExpiresAt` throws
`ARCPError.invalidRequest` synchronously (before any wire emission),
per the v1.0/v1.1 negotiation contract in
[`01-spec-delta.md`](01-spec-delta.md) §3. `subscribe`, `listJobs`,
`ack` similarly check `negotiatedFeatures.contains(.subscribe)` etc.
on entry. `negotiatedFeatures` is `nonisolated let` because it's
fixed post-welcome (audit §5 calls this out).

`Sendable`: actor.

### 4.4 `actor ARCPServer`

```swift
public actor ARCPServer {
    public init(
        config: ServerConfig,
        clock: any Clock<Duration> = ContinuousClock()
    )

    public func registerAgent<A: Agent>(_ type: A.Type) async
    public func registerAgentVersion<A: Agent>(_ type: A.Type, name: String, version: String) async
    public func setDefaultAgentVersion(name: String, version: String) async

    public func accept(_ transport: any Transport) async throws  // attaches one session
}
```

`init` takes a `Clock` so tests can inject `TestClock` (`swift-async-algorithms`
or hand-rolled per [`07-tests.md`](07-tests.md)). `accept` spawns a
`SessionActor` and returns when the session terminates; callers loop
in a `TaskGroup` to accept many.

`Sendable`: actor.

### 4.5 `actor SessionActor` (internal to `ARCPRuntime`)

Not in the public API. Owns one transport's lifetime, the heartbeat
timer (a `Task` ticking on `ContinuousClock`), the `event_seq`
counter, the in-memory resume ring buffer (audit §2.1: SQLite moves
out of default), and the subscriber table mapping `JobId →
[SubscriberId: Continuation]`. Mediates between the per-job actors'
emit calls and the wire by stamping `event_seq` and routing to the
right `Mailbox`.

### 4.6 `actor JobActor` (internal to `ARCPRuntime`)

Not in the public API. One per running job per §7.3. Holds the lease
(immutable), the `Budget` (mutable, hot-path-decremented), the
`JobState`, the `Task` running the agent's `run`, and the
`LeaseEvaluator` (a Sendable value type, can be shared). Receives
`metric` events via the agent's `context.metric(...)` call and
decrements the budget; raises `.budgetExhausted` on the next
authority-bearing op per §9.6.

### 4.7 `JobContext` (passed to agent code)

```swift
public protocol JobContext: Sendable {
    var jobId: JobId { get }
    var sessionId: SessionId { get }
    var lease: Lease { get }                            // immutable
    var budget: Budget? { get async }                   // snapshot

    func log(level: LogLevel, message: String) async throws
    func thought(_ text: String) async throws
    func progress(current: Int, total: Int?, units: String?, message: String?) async throws
    func toolCall(tool: String, args: JSONValue) async throws -> ToolCallHandle
    func metric(name: String, value: Decimal, unit: String?, dimensions: [String: JSONValue]?) async throws
    func artifactRef(uri: String, contentType: String, byteSize: Int?, sha256: String?) async throws

    func streamResult() async throws -> ResultChunkWriter        // §8.4
    func delegate(agent: AgentRef, input: JSONValue, lease: LeaseRequest,
                  constraints: LeaseConstraints?) async throws -> DelegatedJob   // §10

    func checkCancellation() async throws
}

public struct ToolCallHandle: Sendable {
    public let callId: String
    public func emitResult(_ outcome: ToolOutcome) async throws
}

public actor ResultChunkWriter {
    public func write(_ chunk: ResultChunkData, more: Bool) async throws
    public func finish(summary: String?, resultSize: Int?) async throws  // emits terminal job.result
}
```

`budget` is `async` because it crosses an actor hop into `JobActor`;
the snapshot returned is a value-copy of the current `[Currency:
Decimal]` (cheap). `lease` is non-async because it's immutable post-
acceptance and can be held by the context value.

`ResultChunkWriter` is an actor (not a struct) because it owns
mutable `chunk_seq` state and must serialize concurrent writes from
the agent's tasks; misordering chunks violates §8.4. Audit §3
flagged result-chunk assembly as H-risk on the **client** side; the
writer is the runtime-side counterpart.

### 4.8 Client-side `Job` vs `JobSubscription`

```swift
public struct Job: Sendable {
    public let id: JobId
    public let agent: AgentRef                  // resolved name@version per §7.5
    public let acceptedAt: Date
    public let lease: Lease
    public let traceId: TraceId

    // Cancel authority — only the submitter has this (§7.6 last paragraph).
    public func cancel(reason: String? = nil) async throws
    public func events() -> AsyncThrowingStream<JobEvent, Error>
    public func awaitResult() async throws -> JobResult
}

public struct JobSubscription: Sendable {
    public let jobID: JobId
    public let currentStatus: JobStatus
    public let agent: AgentRef
    public let lease: Lease
    public let subscribedFrom: Int
    public let replayed: Bool

    // No `cancel` method — type system prevents it.
    public func events() -> AsyncThrowingStream<JobEvent, Error>
    public func unsubscribe() async throws
}
```

Two distinct types, no shared protocol, no inheritance. Spec §7.6
explicitly says "Subscription does NOT grant the subscriber authority
to cancel the job, mutate its lease, or interact with it beyond
observation." The compile-time enforcement: `subscribe(jobID:)` on
`ARCPClient` returns `JobSubscription`; only `submit(...)` returns
`Job`. A caller cannot pass a `JobSubscription` where `Job` is
expected, and `JobSubscription` has no `cancel()` method to reach for
in the first place. This makes the spec rule unbypassable without a
compiler-noisy `as!` cast (which a code reviewer would catch).

Both are value-type handles (`struct`), not actors. The mutable state
behind them lives in `ARCPClient`; the handle is a Sendable view.

## 5. Hard rules to honor

1. **No `@MainActor` in `ARCPCore` / `ARCPClient` / `ARCPRuntime`.**
   UI is a consumer concern; verified by `grep -r '@MainActor'
   Sources/{ARCPCore,ARCPClient,ARCPRuntime}` returning empty in CI
   ([`07-tests.md`](07-tests.md) owns this lint).
2. **No `DispatchSemaphore` / `DispatchQueue` on any public surface.**
   Hidden inside concrete `Transport` impls if `URLSessionWebSocketTask`
   forces it; nowhere else.
3. **No synchronous blocking I/O in async paths.** Every I/O is
   `async throws`. The `Transport` protocol enforces this at the type
   level.
4. **`final` only when reference identity matters.** Today: nowhere
   on the public surface. If a class appears, it appears because a
   third-party SwiftNIO / URLSession type forces it, and it lives
   inside a transport impl.
5. **`Sendable` declared on every public type.** Auto-derivation
   wherever possible; manual `Sendable` (never `@unchecked`) where
   the compiler can't prove it. The ISO8601 cache stays
   `nonisolated(unsafe)` with the existing justification comment.
6. **`Result` only at validator/authorizer seams.** `LeaseEvaluator.authorize`
   returns `Result<Void, ARCPError>` because the failure category is
   the value the caller routes. Everywhere else, `throws`. No
   `Result` for control flow inside an actor.
