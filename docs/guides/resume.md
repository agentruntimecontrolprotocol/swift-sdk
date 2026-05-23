# Resume

ARCP supports resuming a session from a specific message id, recovering
after a network drop or process crash without replaying from the
beginning (RFC §19).

## How it works

Every envelope is stored in the `EventLog` with its `id` (a ULID).
After a transport drop, open a fresh session and send a `resume`
envelope carrying `after_message_id`; the runtime replays every
envelope with id greater than that cutoff and then resumes live
delivery. It terminates the replay with an `ack` whose `detail`
reports the number of replayed events.

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
