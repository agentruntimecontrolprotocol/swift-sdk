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

The runtime emits `stream.open` on the first chunk, `stream.chunk` for
each fragment, and `stream.closed` when `close(reason:)` is called.

## Stream kinds

| Kind | `StreamKind` case | Typical content-type |
|------|-------------------|----------------------|
| Text | `.text` | `text/plain`, `text/markdown` |
| Event | `.event` | `application/json` |
| Log | `.log` | `text/plain` |
| Thought | `.thought` | `text/markdown` |
| Metric | `.metric` | `application/json` |
| Binary | `.base64Binary` | `application/octet-stream` |

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

Call `sendText` for convenience when the content is UTF-8 text.
Call `sendChunk` to supply the full `StreamChunkPayload` — useful for
binary data (base64 encoded), custom content-types, or explicit sequence
numbers.

## Backpressure

When the client is slow, the runtime applies backpressure: it stops
reading from the `receive` stream until the client sends `stream.ack`.
Handlers detect this via `backpressure` on the send call (it blocks
until the pressure lifts).

See the [`AckBackpressure` sample](../../Samples/AckBackpressure) for
a high-frequency streaming agent and a deliberately slow client.

## Receiving a stream (client)

Streams arrive as `stream.open` / `stream.chunk` / `stream.closed`
envelopes in the subscription stream:

```swift
let subscription = try await client.subscribe(filter: .all, since: nil)
var currentBuffer = ""

for await event in subscription.events {
    switch event.payload {
    case .streamOpen(let o):
        print("stream \(o.streamId) opened kind=\(o.kind)")
    case .streamChunk(let c):
        if let text = c.data { currentBuffer += text }
    case .streamClosed(let c):
        print("stream closed:", c.reason ?? "normal")
        break
    default: break
    }
}
```

## Thought streams

Thought streams (`kind: .thought`) carry the reasoning trace of the
agent. Subscribe with a `.thought` kind filter to observe reasoning
without receiving other stream traffic.

See the [`Reasoning-Streams` sample](../../Samples/Reasoning-Streams).
