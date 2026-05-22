# Resume

ARCP supports resuming a session from a specific message, recovering
after a network drop or process crash without replaying from the
beginning (RFC §19).

## How it works

Every envelope is stored in the `EventLog` with its `id` (a ULID).
When a client reconnects, it passes `after_message_id` in
`session.open`; the runtime replays all stored envelopes after that
ID and then switches to live delivery.

## Reconnecting with a resume point

```swift
// On first connect, store the last message id you processed
var lastSeen: MessageId? = nil

let client1 = try await ARCPClient.open(transport: transport1, auth: auth, client: clientId)
for await envelope in client1.unhandled {
    lastSeen = envelope.id
    // … process …
}

// Network drops. Reconnect and resume from lastSeen
let client2 = try await ARCPClient.open(
    transport: transport2,
    auth: auth,
    client: clientId,
    afterMessageId: lastSeen    // runtime replays from this point
)
```

The runtime will emit a `session.resumed` envelope confirming the
resume point, then replay all envelopes after `lastSeen` before
switching to live traffic.

## Checkpointing

Track the last processed `MessageId` durably to survive process crashes:

```swift
actor Checkpoint {
    private var last: MessageId?
    private let store: any DurableStore   // your persistent store

    func update(_ id: MessageId) async throws {
        last = id
        try await store.set("last_message", value: id.rawValue)
    }

    func load() async throws -> MessageId? {
        guard let raw = try await store.get("last_message") else { return nil }
        return MessageId(rawValue: raw)
    }
}
```

## Artifact retention

Inline-base64 artifacts are swept on a configurable retention schedule.
After the retention window, the envelope is still present in the log
but the artifact data is removed. Clients that need to resume should
process artifact payloads before the window expires.

See `ArtifactStore.defaultRetention` for the default TTL.

## Samples

The [`Resumability` sample](../../Samples/Resumability) actually calls
`exit(137)` mid-job and verifies that a second invocation resumes
correctly via `after_message_id`.
