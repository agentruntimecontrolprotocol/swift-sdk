# Sessions

## Session lifecycle

An ARCP session begins with a four-step handshake (RFC §8.1) and ends
when either side sends `session.close` or the transport closes.

```
client                          runtime
  │── session.open ──────────────▶│  auth block + capabilities
  │◀─ session.challenge ──────────│  nonce  (only if challengeRequired)
  │── session.authenticate ──────▶│  signed token  (only if challenged)
  │◀─ session.accepted ───────────│  session id + runtime identity + negotiated capabilities
  │
  │  [normal operation]
  │
  │── session.close ──────────────▶│
```

## Opening a session (client)

```swift
let client = try await ARCPClient.open(
    transport: transport,
    auth: AuthBlock(scheme: .bearer, token: "secret"),
    client: IdentityBlock(kind: "my-client", version: "1.0"),
    capabilities: Capabilities()
)

// Negotiated capabilities are available immediately
print(client.info.negotiatedCapabilities)
```

`ARCPClient.open` throws `ARCPError.unauthenticated` if the runtime
rejects auth, and `ARCPError.invalidArgument` if the runtime sends an
unexpected envelope before `session.accepted`.

## Accepting a session (server)

```swift
let info = try await runtime.acceptSession(over: transport)
print("session \(info.sessionId) from \(info.principal.subject)")
```

`acceptSession` returns once `session.close` is received or the
transport closes. Call it inside a `Task` or `TaskGroup` to handle
multiple concurrent sessions.

### Multiple sessions

```swift
for await transport in listener.connections {    // your listener
    Task { try await runtime.acceptSession(over: transport) }
}
```

`ARCPRuntime` is an actor — sessions are isolated from each other and
share registered tool handlers.

## Pinging

```swift
let pong = try await client.ping(nonce: "hello")
// pong.nonce == "hello"
```

Ping confirms the session is alive. The runtime echoes the nonce in
`pong.nonce`. The default timeout is 5 seconds; pass `timeout:` to
override.

## Listing open sessions

```swift
let sessions = await runtime.openSessions
for info in sessions {
    print(info.sessionId, info.principal.subject)
}
```

## Closing

```swift
await client.close()   // sends session.close, tears down the transport
```

`close` takes an optional `reason:` string. The runtime stops the
dispatch loop and returns from `acceptSession` when it sees
`session.close` (or when the transport drops).

## SessionInfo

`SessionInfo` carries:

| Field | Type | Description |
|-------|------|-------------|
| `sessionId` | `SessionId` | ULID-prefixed ID (`sess_01...`) |
| `principal` | `AuthenticatedPrincipal` | Authenticated identity (subject + trust level) |
| `clientIdentity` | `IdentityBlock` | What the client sent in `session.open` |
| `runtimeIdentity` | `IdentityBlock` | What the runtime sent back in `session.accepted` |
| `negotiatedCapabilities` | `Capabilities` | Intersection of client and runtime caps |
| `openedAt` | `Date` | When the session was accepted |

## Auth schemes

See [Authentication](auth.md) for bearer tokens, signed JWTs, and
custom validators.
