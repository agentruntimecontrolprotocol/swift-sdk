# Target: `ARCP`

The `ARCP` library target is the core of the Swift SDK. It contains
everything needed to build an ARCP client or runtime:

```swift
import ARCP
```

## Source groups

| Directory | Contents |
|-----------|----------|
| `Auth/` | `AuthValidator` protocol, `BearerAuthValidator`, `JWTAuthValidator`, `CompositeAuthValidator` |
| `Client/` | `ARCPClient` actor, `ResultChunkStream`, `PermissionHandler` |
| `Envelope/` | `Envelope`, `MessageType`, `JSONValue`, `Priority` |
| `Errors/` | `ARCPError`, `ErrorCode` |
| `Extensions/` | `ExtensionRegistry` |
| `Ids/` | ULID generator, typed id aliases (`MessageId`, `SessionId`, `JobId`, `StreamId`, `SubscriptionId`, `TraceId`, `SpanId`, `LeaseId`, `IdempotencyKey`, `ArtifactId`) |
| `Messages/` | Payload structs — one file per RFC section |
| `Runtime/` | `ARCPRuntime`, `JobManager`, `JobContext`, `ToolHandler`, `SubscriptionManager`, `ArtifactStore`, `CredentialManager`, `BudgetTracker`, `ModelUsePolicy`, ... |
| `Store/` | `EventLog` (SQLite-backed) + bundled `schema.sql` |
| `Trace/` | `TraceContext`, `Tracing` task-local |
| `Transport/` | `Transport` protocol + `MemoryTransport`, `StdioTransport`, `WebSocketTransport`, `WebSocketClient.connect(...)` |

## Key public types

### Protocols

| Type | Description |
|------|-------------|
| `Transport` | Bidirectional envelope channel (RFC §22) |
| `ToolHandler` | Server-side handler: `execute(invocation:context:) async throws -> ToolOutput` |
| `JobContext` | Injected into every handler — progress, streaming, cancel, charging, permissions, credential rotation |
| `StreamHandle` | Returned by `JobContext.openStream`; `sendText` / `sendChunk` / `close` / `error` |
| `AuthValidator` | Validates an `AuthBlock` and returns an `AuthenticatedPrincipal` |
| `CredentialProvisioner` | Issues / rotates / revokes `ProvisionedCredential` for leased jobs |
| `PermissionHandler` | Client-side permission challenge handler |

### Actors

| Type | Description |
|------|-------------|
| `ARCPRuntime` | Hosts sessions, routes envelopes, owns `EventLog` / `SubscriptionManager` / `ArtifactStore` |
| `ARCPClient` | Executes the handshake, exposes `invoke`, `ping`, `cancelJob`, `close`, `send` + `unhandled` |
| `SubscriptionManager` | Routes outbound envelopes to live subscribers; manages backfill |
| `ArtifactStore` | Inline-base64 artifact lifecycle + retention sweep |
| `EventLog` | SQLite-backed append-only log of all envelopes |
| `ExtensionRegistry` | Namespace validation + unknown-type disposition |

### Structs / enums

| Type | Description |
|------|-------------|
| `Envelope` | Wire message — `id`, `sessionId`, `jobId`, `correlationId`, `traceId`, `priority`, `payload`, ... |
| `MessageType` | Discriminated union of all in-scope wire types (plus `.unknown(typeName:payload:)`) |
| `JSONValue` | Recursive JSON value (`object`, `array`, `string`, `int`, `double`, `bool`, `null`) |
| `Capabilities` | Declared and negotiated feature flags |
| `JobState` | `accepted`, `queued`, `running`, `blocked`, `paused`, `completed`, `failed`, `cancelled` |
| `ARCPError` | All SDK errors; maps to `ErrorCode` on the wire |
| `ErrorCode` | RFC §18.2 taxonomy with `isRetryableByDefault` |
| `ToolOutput` | `.value(JSONValue)`, `.ref(ArtifactRef)`, `.empty`, `.streamed(resultId:size:summary:)` |
| `BudgetTracker` | Per-job cost counters seeded from `cost_budget` on `tool.invoke` |
| `ModelUsePolicy` | Wildcard pattern matching for `model.use` lease constraints |

## Dependencies

| Package | Reason |
|---------|--------|
| `swift-log` | Structured logging via `Logger` |
| `swift-nio` + `NIOWebSocket` / `NIOHTTP1` | Async networking layer used by the WebSocket transport |
| `websocket-kit` | WebSocket client transport |
| `jwt-kit` (>=5.1, <5.3) | `signed_jwt` auth scheme |
| `SQLite.swift` | `EventLog` and artifact persistence |
| `swift-docc-plugin` | DocC generation for `swiftpackageindex.com` |

## Version

Wire-protocol version: `ARCPVersion.wire = "1.1"`.
SDK build identifier: `ARCPVersion.sdk = "0.1.0-dev"`.
Declared in `Sources/ARCP/Version.swift`.
