# Target: `ARCP`

The `ARCP` library target is the core of the Swift SDK. It contains
everything needed to build an ARCP client or runtime:

```swift
import ARCP
```

## Source groups

| Directory | Contents |
|-----------|----------|
| `Auth/` | `BearerAuthValidator`, `JWTAuthValidator`, `AuthValidator` protocol |
| `Client/` | `ARCPClient` actor, `ResultChunkStream` |
| `Envelope/` | `Envelope`, `MessageType`, `JSONValue`, `Priority` |
| `Errors/` | `ARCPError`, `ErrorCode` |
| `Extensions/` | `ExtensionRegistry` |
| `Ids/` | ULID generator, `MessageId`, `SessionId`, `JobId`, `StreamId`, … |
| `Messages/` | Payload structs — one file per RFC section |
| `Runtime/` | `ARCPRuntime`, `JobManager`, `JobContext`, `ToolHandler`, subsystems |
| `Store/` | `EventLog` (SQLite) |
| `Trace/` | `TraceContext` (W3C traceparent) |
| `Transport/` | `Transport` protocol + `MemoryTransport`, `StdioTransport`, `WebSocketTransport` |

## Key public types

### Protocols

| Type | Description |
|------|-------------|
| `Transport` | Bidirectional envelope channel (RFC §22) |
| `ToolHandler` | Server-side handler: `execute(invocation:context:) async throws -> ToolOutput` |
| `JobContext` | Injected into every handler — progress, streaming, cancel, charging, permissions |
| `AuthValidator` | Validates an `AuthBlock` and returns an `AuthenticatedPrincipal` |
| `CredentialProvisioner` | Issues / rotates / revokes `ProvisionedCredential` for leased jobs |

### Actors

| Type | Description |
|------|-------------|
| `ARCPRuntime` | Hosts sessions, routes envelopes, owns `EventLog` / `SubscriptionManager` / `ArtifactStore` |
| `ARCPClient` | Executes the handshake, exposes `invoke`, `subscribe`, `ping` |
| `SubscriptionManager` | Routes outbound envelopes to live subscribers; manages backfill |
| `ArtifactStore` | Inline-base64 artifact lifecycle + retention sweep |
| `EventLog` | SQLite-backed append-only log of all envelopes |

### Structs / enums

| Type | Description |
|------|-------------|
| `Envelope` | Wire message: `id`, `sessionId`, `type`, `payload`, `priority`, `traceId` |
| `MessageType` | Discriminated union of all in-scope wire types |
| `JSONValue` | Recursive JSON value (`object`, `array`, `string`, `number`, `bool`, `null`) |
| `Capabilities` | Declared and negotiated feature flags |
| `ARCPError` | All SDK errors; maps to `ErrorCode` on the wire |
| `ErrorCode` | RFC §18.2 taxonomy with retryability (`isRetryableByDefault`) |
| `ToolOutput` | `.value(JSONValue)`, `.ref(ArtifactRef)`, `.empty`, `.streamed(…)` |
| `BudgetTracker` | Per-job cost counters seeded from `cost_budget` on `tool.invoke` |
| `ModelUsePolicy` | Wildcard pattern matching for `model.use` lease constraints |

## Dependencies

| Package | Reason |
|---------|--------|
| `swift-log` | Structured logging via `Logger` |
| `swift-nio` + `NIOHTTP1` / `NIOWebSocket` | Async networking layer |
| `websocket-kit` | WebSocket client transport |
| `jwt-kit` (< 5.3) | `signed_jwt` auth scheme |
| `SQLite.swift` | `EventLog` and `ArtifactStore` persistence |

## Version

Current SDK version: `1.1.0`. Wire version: `1.1`.
Declared in `Sources/ARCP/Version.swift`.
