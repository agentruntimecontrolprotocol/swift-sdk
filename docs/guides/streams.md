# Streams

ARCP streams deliver incremental output — tokens, log lines, thought
traces, metric samples, or binary blobs — over a session while a job
is still running (RFC §11).

## Opening a stream (handler side)

```swift
func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
    let handle = try await context.openStream(
        kind: .text,
        contentType: "text/plain",
        encoding: nil
    )
    for token in await llm.generate(prompt) {
        try await handle.sendText(token, sequence: nil)
    }
    try await handle.close(reason: nil)
    return .empty   // content was in the stream
}
```

The runtime emits `stream.open` when `openStream` is called,
`stream.chunk` for each fragment, and `stream.close` when
`close(reason:)` is called. Errors emitted from the handler surface as
`stream.error`.

## Stream kinds

| `StreamKind` | Typical content-type | Notes |
|--------------|----------------------|-------|
| `.text` | `text/plain`, `text/markdown` | UTF-8 fragments |
| `.binary` | `application/octet-stream` | Base64-encoded in `data` (v0.1 always inlines) |
| `.event` | `application/json` | Structured events |
| `.log` | `text/plain` | Log lines from the handler |
| `.thought` | `text/markdown` | Reasoning trace |
| `.metric` | `application/json` | Periodic metric samples |

## StreamHandle

```swift
public protocol StreamHandle: Sendable {
    var streamId: StreamId { get }
    func sendText(_ text: String, sequence: Int?) async throws
    func sendChunk(_ payload: StreamChunkPayload) async throws
    func close(reason: String?) async throws
    func error(_ error: ARCPError) async throws
}
```

Call `sendText` for convenience when the content is UTF-8 text. Call
`sendChunk` to supply the full `StreamChunkPayload` — useful for binary
data (base64-encoded in `data`), custom `content_type`, explicit
`sequence`, or attaching `attributes`.

## Backpressure

When the client is slow, the runtime applies backpressure: `sendText`
and `sendChunk` suspend until the consumer drains and the in-process
buffer drops below the high-water mark. The `BACKPRESSURE_OVERFLOW`
error (`ARCPError.backpressureOverflow`) is emitted only when the
runtime is forced to drop frames.

See the [`AckBackpressure` sample](../../Samples/AckBackpressure) for a
high-frequency streaming agent paired with a deliberately slow consumer.

## Receiving a stream (client)

Streams arrive as `stream.open` / `stream.chunk` / `stream.close`
envelopes. Either drain `client.unhandled` directly, or open a
subscription with `streamIds:` set in the filter:

```swift
try await client.send(
    Envelope(
        sessionId: client.info.sessionId,
        payload: .subscribe(
            SubscribePayload(filter: SubscriptionFilter())
        )
    )
)

var buffer = ""
for await envelope in client.unhandled {
    switch envelope.payload {
    case .streamOpen(let o):
        print("stream \(envelope.streamId?.rawValue ?? "?") opened kind=\(o.kind)")
    case .streamChunk(let c):
        if let text = c.content { buffer += text }
    case .streamClose(let c):
        print("stream closed:", c.reason ?? "normal")
    case .streamError(let e):
        print("stream error:", e.error.code.rawValue, e.error.message)
    default:
        continue
    }
}
```

## Thought streams

Thought streams (`kind: .thought`) carry the reasoning trace of the
agent. Subscribers can filter on `types: ["stream.open", "stream.chunk", "stream.close"]`
and ignore other traffic, or look at `StreamOpenPayload.kind` to keep
only the thought streams.

See the [`Reasoning-Streams` sample](../../Samples/Reasoning-Streams).
