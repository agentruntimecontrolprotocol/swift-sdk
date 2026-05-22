# Jobs

A **job** is a single tool invocation. The client submits it via
`tool.invoke`; the runtime runs the handler, tracks progress, and
eventually emits `job.completed`, `job.failed`, or `job.cancelled`.

## Registering a tool handler

```swift
struct SummariseHandler: ToolHandler {
    let name = "summarise"

    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        let text = invocation.arguments["text"]?.stringValue ?? ""
        let summary = await mySummariser(text)                  // your logic
        try await context.reportProgress(percent: 100, message: "done", attributes: nil)
        return .value(.string(summary))
    }
}

runtime.register(SummariseHandler())
```

Handlers run inside a Swift `Task`. Structured concurrency is the
natural model for fan-out or sequential steps.

## Invoking a tool (client)

```swift
// Fire-and-forget: wait for completion
let (outcome, jobId) = try await client.invoke(
    tool: "summarise",
    arguments: .object(["text": .string(input)])
)

switch outcome {
case .completed(let result):
    print(result.result ?? "no result")
case .failed(let err):
    print("error:", err.code, err.message)
case .cancelled(let c):
    print("cancelled:", c.reason ?? "")
}
```

### With a progress stream

```swift
let (progressStream, jobId) = try await client.invokeWithProgress(
    tool: "summarise",
    arguments: .object(["text": .string(input)])
)

for await progress in progressStream {
    if let pct = progress.percent { print("  \(pct)%") }
    if let msg = progress.message { print(" ", msg) }
}

let outcome = await progressStream.outcome   // JobOutcome
```

### Idempotency key

Retry safely by supplying the same idempotency key:

```swift
let key = IdempotencyKey("my-dedupe-key")
let (outcome, _) = try await client.invoke(
    tool: "process",
    arguments: args,
    idempotencyKey: key
)
```

If the runtime has already accepted an invocation with that key, it
returns the same `job_id` and queues no duplicate work
(see [`IdempotentRetry` sample](../../Samples/IdempotentRetry)).

## Job states

```
submitted → accepted → running → completed
                              ↘ failed
                              ↘ cancelled
```

State transitions are logged to the `EventLog`. Retrieve them via
`runtime.eventLog.query(sessionId:)`.

## Cancellation

Cooperative: call `context.checkCancellation()` at safe points in the
handler. The client cancels with `client.cancel(jobId:)`.

```swift
func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
    for chunk in bigDataSet {
        try await context.checkCancellation()   // throws ARCPError.cancelled
        process(chunk)
    }
    return .value(result)
}
```

The [`Cancellation` sample](../../Samples/Cancellation) demonstrates
both cooperative cancel and interrupt.

## Interrupts

An interrupt is a temporary pause signal. The handler receives a
`job.interrupt` envelope; the runtime sends `ack` when the handler
acknowledges it. Different from cancellation — the job can resume after
the interrupt is handled.

## Listing jobs

```swift
let jobs = try await client.listJobs()
for job in jobs { print(job.jobId, job.status) }
```

## Heartbeats

The runtime expects periodic heartbeats from long-running handlers.
The default heartbeat interval is 30 seconds. If the runtime stops
receiving heartbeats it emits `HEARTBEAT_LOST` and cancels the job.

```swift
func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
    for step in longPipeline {
        try await context.heartbeat()    // resets the heartbeat timer
        process(step)
    }
    return .value(result)
}
```

See the [`Heartbeats` sample](../../Samples/Heartbeats).
