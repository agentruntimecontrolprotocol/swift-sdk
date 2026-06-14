# Resume

ARCP supports resuming a session from a specific message id, recovering
after a network drop or process crash without replaying from the
beginning (RFC §19).

## Scope in this SDK

This release implements **same-session event-log replay only**:

- After a transport drop, you reconnect over a fresh transport. Resume
  replay is scoped to the active `session_id` on reconnect and starts
  after `after_message_id` in that same session's event log — it succeeds
  only when the original `session_id` survives the reconnect.
- **Cross-session resume is not implemented** — i.e. you cannot use
  `after_message_id` from a prior session to recover events that the
  prior session emitted. The runtime has no mapping from one session id
  to another, and the replay query is scoped to the current session id.
  Resume in this SDK works only when the same session id survives the
  reconnect (e.g. when the transport drops but the runtime can be told
  to continue using the same `session_id`).
- `checkpoint_id` is **not** implemented and returns
  `ARCPError.unimplemented`.
- `include_open_streams` is currently ignored — open streams are not
  re-emitted by the runtime.

A future release may add a resume-token handshake that authorizes
cross-session continuation.

## How it works

Every envelope is stored in the `EventLog` with its `id` (a ULID).
A `resume` envelope carrying `after_message_id` triggers the runtime to
replay every envelope with id greater than that cutoff (for the current
session) and then resume live delivery. It terminates the replay with
an `ack` whose `detail` reports the number of replayed events.

## Reconnecting with a resume point

```swift
// On first connect, remember the last message id we saw.
var lastSeen: MessageId?
let client = try await ARCPClient.open(
    transport: transport,
    auth: AuthBlock(scheme: .bearer, token: token),
    client: IdentityBlock(kind: "resumable", version: "1.0"),
    capabilities: Capabilities(durableJobs: true)
)
let drainer = Task {
    for await envelope in client.unhandled {
        lastSeen = envelope.id
    }
}

// ... transport drops ...

// Reconnect over a fresh transport, then ask the runtime to replay.
let resumed = try await ARCPClient.open(
    transport: try await WebSocketClient.connect(url: url, eventLoopGroup: group),
    auth: AuthBlock(scheme: .bearer, token: token),
    client: IdentityBlock(kind: "resumable", version: "1.0"),
    capabilities: Capabilities(durableJobs: true)
)
try await resumed.send(
    Envelope(
        sessionId: resumed.info.sessionId,
        payload: .resume(
            ResumePayload(afterMessageId: lastSeen, includeOpenStreams: true)
        )
    )
)
// The runtime replays every envelope with id > lastSeen, terminates
// with an `ack`, then resumes live streaming.
drainer.cancel()
```

`ResumePayload` carries:

| Field | Type | Description |
|-------|------|-------------|
| `afterMessageId` | `MessageId?` | Replay every stored envelope with id strictly greater than this |
| `checkpointId` | `String?` | Reserved for checkpoint-based resume (deferred to v0.2) |
| `includeOpenStreams` | `Bool` | If true, re-emit `stream.open` for streams still alive |

## Checkpointing

Track the last processed `MessageId` durably to survive process crashes:

```swift
actor Checkpoint {
    private let store: any DurableStore   // your persistent store

    func update(_ id: MessageId) async throws {
        try await store.set("last_message", value: id.rawValue)
    }

    func load() async throws -> MessageId? {
        guard let raw = try await store.get("last_message") else { return nil }
        return MessageId(raw)
    }
}
```

## Artifact retention

Inline-base64 artifacts are swept on a configurable retention schedule
(`Capabilities.artifactRetention`). After the retention window the
envelope is still present in the log but the artifact data is removed.
Clients that need to resume should process artifact payloads before
the window expires.

## Samples

The [`Resumability` sample](../../Samples/Resumability) actually calls
`exit(137)` mid-job and verifies that a second invocation resumes
correctly via `after_message_id`.
