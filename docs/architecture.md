# Architecture

## Layer diagram

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/architecture-dark.svg">
  <img alt="ARCP Swift SDK — layer diagram" src="diagrams/architecture-light.svg">
</picture>

## Core types

### `Envelope` (RFC §6.1)

Every ARCP message is an `Envelope`:

```swift
public struct Envelope: Sendable, Hashable, Codable {
    public var arcp: String          // wire version, e.g. "1.1"
    public var id: MessageId         // ULID
    public var timestamp: Date
    public var sessionId: SessionId?
    public var jobId: JobId?
    public var streamId: StreamId?
    public var subscriptionId: SubscriptionId?
    public var traceId: TraceId?
    public var correlationId: MessageId?
    public var idempotencyKey: IdempotencyKey?
    public var priority: Priority
    public var payload: MessageType
    // ...
}
```

`MessageType` has one case per in-scope wire type (e.g.,
`.toolInvoke`, `.jobProgress`, `.streamChunk`). Unknown types decode as
`.unknown(typeName:payload:)` and are accepted, dropped, or `nack`-ed by
`ExtensionRegistry.disposition(forUnknown:optional:)` per RFC §21.3.

### `ARCPRuntime`

`ARCPRuntime` is a Swift actor that owns:

| Subsystem | Role |
|-----------|------|
| `EventLog` | SQLite-backed, replayable by `sessionId` and `MessageId` cutoff |
| `SubscriptionManager` | Routes every outbound envelope to matching subscribers, including backfill |
| `ArtifactStore` | Manages inline-base64 artifacts and retention sweeps |
| `JobManager` (per session) | Runs tools as `Task`s, drives the job FSM, owns leases and budgets |
| `CapabilityNegotiator` | Intersects runtime and client capability sets (RFC §7) |
| `ExtensionRegistry` | Validates extension namespaces and disposes of unknown types (RFC §21) |
| `CredentialManager` | Issues / rotates / revokes lease-bound credentials (when a provisioner is configured) |

Register tool handlers once; all future sessions inherit them:

```swift
await runtime.register(MyToolHandler())
```

Drive a session by calling:

```swift
let info = try await runtime.acceptSession(over: transport)
```

`acceptSession` completes the handshake, then blocks on the dispatch
loop until `session.close` is received or the transport closes.

### `ARCPClient`

`ARCPClient` is a Swift actor that:

- Executes the four-step handshake (RFC §8.1) in `open(...)`
- Exposes `invoke(tool:arguments:costBudget:modelUse:leaseConstraints:idempotencyKey:)` returning an `InvocationResult` with `jobId`, terminal `JobOutcome`, and a progress `AsyncStream<JobProgressPayload>`
- Exposes `ping(nonce:timeout:)`, `cancelJob(_:reason:deadlineMs:)`, `close(reason:)`
- Exposes `resultChunks(for:)` for joining a `ResultChunkStream` from a streamed result
- Handles `permission.request` via a pluggable `PermissionHandler`
- Surfaces every envelope it does not consume internally on `unhandled` — clients drive subscriptions, resume, list-jobs, etc. by sending the corresponding payload via `send(_:)` and reading the responses from `unhandled`

### `Transport`

```swift
public protocol Transport: Sendable {
    func send(_ envelope: Envelope) async throws
    var receive: AsyncStream<Envelope> { get }
    func close() async
}
```

See [Transports](transports.md) for concrete implementations.

## Wire format

ARCP uses **NDJSON** framing. Each line is one JSON object matching
the `Envelope` schema (RFC §6.1). The `type` field is a string
(e.g., `"tool.invoke"`) that drives decode into the correct payload
struct via `MessageType`'s `Codable` implementation.

## Source layout

```
Sources/
├── ARCP/
│   ├── Auth/          BearerAuthValidator, JWTAuthValidator, CompositeAuthValidator
│   ├── Client/        ARCPClient, ResultChunkStream, PermissionHandler
│   ├── Envelope/      Envelope, MessageType, JSONValue, Priority
│   ├── Errors/        ARCPError, ErrorCode
│   ├── Extensions/    ExtensionRegistry
│   ├── Ids/           ULID generation, typed ID aliases
│   ├── Messages/      Payload structs, one file per RFC section
│   ├── Runtime/       ARCPRuntime and all subsystems
│   ├── Store/         EventLog (SQLite)
│   ├── Trace/         TraceContext, Tracing task-local
│   └── Transport/     MemoryTransport, StdioTransport, WebSocketTransport
└── arcp-cli/          `arcp` CLI entry point
```

## Diagrams

The architecture layer diagram above is rendered from
[`docs/diagrams/architecture-light.dot`](diagrams/architecture-light.dot)
(light) and [`architecture-dark.dot`](diagrams/architecture-dark.dot) (dark).
The job lifecycle state diagram is in
[`docs/diagrams/job-fsm.dot`](diagrams/job-fsm.dot).
