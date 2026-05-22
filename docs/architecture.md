# Architecture

## Layer diagram

```
┌───────────────────────────────────────────────────────┐
│                   Application code                    │
│         (ToolHandler, JobContext, CredentialProvisioner)│
└──────────────────────┬───────────────────┬────────────┘
                       │                   │
         ┌─────────────▼──────┐   ┌────────▼───────────┐
         │    ARCPRuntime     │   │    ARCPClient       │
         │  (server-side)     │   │  (client-side)      │
         └─────────────┬──────┘   └────────┬────────────┘
                       │                   │
         ┌─────────────▼───────────────────▼────────────┐
         │           Transport  (RFC §22)                │
         │  MemoryTransport · StdioTransport · WebSocket │
         └──────────────────────────────────────────────┘
                       │
         ┌─────────────▼──────────────────────────────┐
         │           Envelope  (RFC §6.1)              │
         │  id · session_id · type · payload · …       │
         └────────────────────────────────────────────┘
```

## Core types

### `Envelope` (RFC §6.1)

Every ARCP message is an `Envelope`:

```swift
public struct Envelope: Sendable, Codable {
    public let id: MessageId         // ULID
    public let sessionId: SessionId?
    public let type: MessageType     // discriminated-union tag
    public let payload: MessagePayload
    public let priority: Priority?
    public let traceId: TraceId?
    // …
}
```

`MessageType` has one case per in-scope wire type (e.g.,
`.toolInvoke`, `.jobProgress`, `.streamChunk`). Unknown types decode as
`.unknown(typeName:payload:)` and are rejected per RFC §21.3.

### `ARCPRuntime`

`ARCPRuntime` is a Swift actor that owns:

| Subsystem | Role |
|-----------|------|
| `EventLog` | SQLite-backed, queryable by session, job, or message type |
| `SubscriptionManager` | Routes every outbound envelope to matching subscribers |
| `ArtifactStore` | Manages inline-base64 artifacts and retention sweeps |
| `JobManager` (per session) | Runs tools as `Task`s, drives the job FSM, manages heartbeats |
| `CapabilityNegotiator` | Intersects runtime and client capability sets (RFC §7) |
| `CredentialManager` | Issues / rotates / revokes lease-bound credentials |

Register tool handlers once; all future sessions inherit them:

```swift
runtime.register(MyToolHandler())
```

Drive a session by calling:

```swift
let info = try await runtime.acceptSession(over: transport)
```

`acceptSession` blocks until `session.close` or the transport closes.

### `ARCPClient`

`ARCPClient` is a Swift actor that:

- Executes the four-step handshake (RFC §8.1) in `open(…)`
- Exposes `invoke(tool:arguments:)` returning `(JobOutcome, JobId?)`
- Exposes `invokeWithProgress(…)` returning a progress `AsyncStream`
- Handles `permission.request` via a pluggable `PermissionHandler`
- Exposes `subscribe(filter:since:)` for event subscriptions

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
│   ├── Auth/          BearerAuthValidator, JWTAuthValidator
│   ├── Client/        ARCPClient, ResultChunkStream
│   ├── Envelope/      Envelope, MessageType, JSONValue
│   ├── Errors/        ARCPError, ErrorCode
│   ├── Extensions/    ExtensionRegistry
│   ├── Ids/           ULID generation, typed ID aliases
│   ├── Messages/      Payload structs, one file per RFC section
│   ├── Runtime/       ARCPRuntime and all subsystems
│   ├── Store/         EventLog (SQLite)
│   ├── Trace/         TraceContext
│   └── Transport/     MemoryTransport, StdioTransport, WebSocketTransport
└── arcp-cli/          `arcp` CLI entry point
```

## Diagrams

SVG state diagrams for the session, job, stream, subscription, and lease
life cycles are in [`docs/diagrams/`](diagrams/).
