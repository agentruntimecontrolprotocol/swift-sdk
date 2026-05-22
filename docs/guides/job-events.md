# Job Events

Handlers emit events during a job's lifetime using the `JobContext`
protocol. Each event is an `Envelope` stored in the `EventLog` and
routed to any matching subscriptions.

## Progress

Report deterministic progress with a percent value:

```swift
try await context.reportProgress(percent: 42.0, message: "Indexing…", attributes: nil)
```

Report structured progress (ARCP v1.1 §8.2.1) with `current`/`total`/`units`:

```swift
try await context.reportProgress(current: 42, total: 100, units: "files", message: "Indexing…")
```

Both forms are available. Structured progress is preferred because it
lets clients render accurate gauges.

## Result chunks

For large results, stream them as `job.result_chunk` fragments
(ARCP v1.1 §8.4) instead of returning everything in `job.completed`:

```swift
func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
    let resultId = Ulid.next()
    var seq: UInt64 = 0
    for chunk in bigOutput.chunks(ofCount: 4096) {
        let isLast = chunk == bigOutput.last
        try await context.emitResultChunk(
            resultId: resultId,
            chunkSeq: seq,
            data: chunk,
            encoding: .utf8,
            more: !isLast
        )
        seq += 1
    }
    return .streamed(resultId: resultId, size: UInt64(bigOutput.count), summary: "big result")
}
```

The terminal `job.completed` carries `resultId` / `resultSize` /
`summary` markers. The client collects chunks via `ResultChunkStream`.

See the [`ResultChunk` sample](../../Samples/ResultChunk).

## Streams

Open a real-time event stream for incremental output:

```swift
let handle = try await context.openStream(kind: .text, contentType: "text/plain", encoding: nil)
for token in llmTokenStream {
    try await handle.sendText(token, sequence: nil)
}
try await handle.close(reason: nil)
return .empty  // result delivered via stream
```

Stream kinds: `.text`, `.event`, `.log`, `.thought`, `.metric`,
`.base64Binary`.

See the [`Reasoning-Streams` sample](../../Samples/Reasoning-Streams)
for a `thought`-stream example.

## Log events

```swift
try await context.log(level: .info, message: "Processing file 1 of 42", attributes: nil)
try await context.log(
    level: .warning,
    message: "rate limit hit",
    attributes: ["retry_after": .int(5)]
)
```

Log levels: `.debug`, `.info`, `.warning`, `.error`.

## Metric events

```swift
try await context.metric(name: "tokens.processed", value: 1024, unit: "count", dims: nil)
try await context.metric(
    name: "latency.llm_call",
    value: 0.312,
    unit: "s",
    dims: ["model": .string("gpt-4o")]
)
```

## Cost tracking

Emit named cost metrics and decrement the job's `cost.budget`:

```swift
try await context.charge(name: "cost.tokens", amount: 0.002, currency: "USD")
// Also emits cost.budget.remaining automatically
```

See [Leases](leases.md) for budget setup and the
[`CostBudget` sample](../../Samples/CostBudget).

## Receiving events (client)

Subscribe to all events in a session:

```swift
let subscription = try await client.subscribe(filter: .all, since: nil)
for await event in subscription.events {
    switch event.payload {
    case .jobProgress(let p):  print("progress:", p.percent ?? -1)
    case .streamChunk(let c):  print("chunk:", c.data)
    case .log(let l):          print("log:", l.message)
    case .metric(let m):       print("metric:", m.name, m.value)
    default: break
    }
}
```

See [Subscriptions](subscriptions.md) for filter syntax.
