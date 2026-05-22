# Sessions

## Session lifecycle

An ARCP session begins with a four-step handshake (RFC §8.1) and ends
when either side sends `session.close` or the transport closes.

```
client                          runtime
  │── session.open ──────────────▶│  auth block + capabilities
  │◀─ session.challenge ──────────│  nonce  (if challengeRequired)
  │── session.auth ───────────────▶│  signed token  (if challenged)
  │◀─ session.accepted ───────────│  negotiated capabilities
  │
  │  [normal operation]
  │
  │── session.close ──────────────▶│
  │◀─ session.close ──────────────│
```

## Opening a session (client)

```swift
let client = try await ARCPClient.open(
    transport: transport,
    auth: AuthBlock(scheme: .bearer, token: "secret"),
    client: IdentityBlock(name: "my-client", version: "1.0"),
    capabilities: Capabilities()
)

// Negotiated capabilities are available immediately
print(client.info.negotiatedCapabilities)
```

`ARCPClient.open` throws `ARCPError.unauthenticated` if the handshake
is rejected or times out.

## Accepting a session (server)

```swift
let info = try await runtime.acceptSession(over: transport)
print("session \(info.sessionId) from \(info.principal?.subject ?? "anon")")
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
`pong.nonce`.

## Listing open sessions

```swift
let sessions = await runtime.openSessions
for info in sessions {
    print(info.sessionId, info.principal?.subject ?? "anon")
}
```

## Closing

```swift
try await client.close()   // sends session.close, waits for echo, cleans up
```

The runtime closes automatically if the transport drops without
`session.close`.

## SessionInfo

`SessionInfo` carries:

| Field | Type | Description |
|-------|------|-------------|
| `sessionId` | `SessionId` | ULID-prefixed ID (`sess_01…`) |
| `principal` | `AuthenticatedPrincipal?` | Authenticated identity, if any |
| `negotiatedCapabilities` | `Capabilities` | Intersection of client and runtime caps |
| `openedAt` | `Date` | When the session was accepted |

## Auth schemes

See [Authentication](auth.md) for bearer tokens, signed JWTs, and
custom validators.
