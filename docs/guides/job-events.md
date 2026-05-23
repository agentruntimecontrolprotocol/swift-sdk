# Job Events

Handlers emit events during a job's lifetime using the `JobContext`
protocol. Each event is an `Envelope` stored in the `EventLog` and
routed to any matching subscriptions.

## Progress

Report deterministic progress with a percent value:

```swift
try await context.reportProgress(percent: 42.0, message: "Indexing...", attributes: nil)
```

Report structured progress (ARCP v1.1 §8.2.1) with
`current`/`total`/`units`:

```swift
try await context.reportProgress(current: 42, total: 100, units: "files", message: "Indexing...")
```

Both forms are available. The structured form derives a percent
automatically (when `total > 0`) and lets clients render accurate
gauges.

## Result chunks

For large results, stream them as `job.result_chunk` fragments
(ARCP v1.1 §8.4) instead of returning everything in `job.completed`:

```swift
func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
    let resultId = Ulid.next()
    var seq: UInt64 = 0
    let pieces = bigOutput.chunked(intoSize: 4096)
    for (index, chunk) in pieces.enumerated() {
        let isLast = index == pieces.count - 1
        try await context.emitResultChunk(
            resultId: resultId,
            chunkSeq: seq,
            data: chunk,
            encoding: .utf8,
            more: !isLast
        )
        seq += 1
    }
    return .streamed(
        resultId: resultId,
        size: UInt64(bigOutput.utf8.count),
        summary: "big result"
    )
}
```

The terminal `job.completed` carries the same `resultId` along with
`resultSize` / `summary`. The client collects chunks via
`client.resultChunks(for: jobId)`, which returns a `ResultChunkStream`.

See the [`ResultChunk` sample](../../Samples/ResultChunk).

## Streams

Open a real-time stream for incremental output:

```swift
let handle = try await context.openStream(kind: .text, contentType: "text/plain", encoding: nil)
for token in llmTokenStream {
    try await handle.sendText(token, sequence: nil)
}
try await handle.close(reason: nil)
return .empty  // result delivered via stream
```

Stream kinds (`StreamKind`): `.text`, `.binary`, `.event`, `.log`,
`.thought`, `.metric`.

See the [`Reasoning-Streams` sample](../../Samples/Reasoning-Streams)
for a `thought`-stream example.

## Log events

```swift
try await context.log(level: .info, message: "Processing file 1 of 42", attributes: nil)
try await context.log(
    level: .warn,
    message: "rate limit hit",
    attributes: ["retry_after": .int(5)]
)
```

`LogLevel` cases follow the wire taxonomy (RFC §17.2): `.trace`,
`.debug`, `.info`, `.warn`, `.error`, `.critical`.

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

Open a subscription by sending a `subscribe` envelope and reading the
`subscribe.event` payloads from `unhandled`:

```swift
try await client.send(
    Envelope(
        sessionId: client.info.sessionId,
        payload: .subscribe(
            SubscribePayload(filter: SubscriptionFilter())
        )
    )
)

for await envelope in client.unhandled {
    guard case .subscribeEvent(let payload) = envelope.payload else { continue }
    print("event:", payload.event)
}
```

See [Subscriptions](subscriptions.md) for filter fields.
