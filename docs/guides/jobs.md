# Jobs

A **job** is a single tool invocation. The client submits it via
`tool.invoke`; the runtime runs the handler, tracks progress, and
eventually emits `job.completed`, `job.failed`, or `job.cancelled`.

## Registering a tool handler

```swift
struct SummariseHandler: ToolHandler {
    let name = "summarise"

    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        guard case .object(let args) = invocation.arguments,
              case .string(let text) = args["text"] else {
            throw ARCPError.invalidArgument(field: "text", detail: "missing or not a string")
        }
        let summary = await mySummariser(text)                  // your logic
        try await context.reportProgress(percent: 100, message: "done", attributes: nil)
        return .value(.string(summary))
    }
}

await runtime.register(SummariseHandler())
```

Handlers run inside a Swift `Task`. Structured concurrency is the
natural model for fan-out or sequential steps.

## Invoking a tool (client)

```swift
let invocation = try await client.invoke(
    tool: "summarise",
    arguments: .object(["text": .string(input)])
)

switch invocation.outcome {
case .completed(let payload):
    print(payload.result ?? .null)
case .failed(let err):
    print("error:", err.code.rawValue, err.message)
case .cancelled(let c):
    print("cancelled:", c.reason)
}
```

`invoke` returns an `InvocationResult` with three fields:

| Field | Type | Description |
|-------|------|-------------|
| `jobId` | `JobId?` | Server-assigned id (set as soon as `job.accepted` arrives) |
| `outcome` | `JobOutcome` | Terminal `.completed` / `.failed` / `.cancelled` |
| `progress` | `AsyncStream<JobProgressPayload>` | Drained progress events; finishes alongside the outcome |

### Consuming progress

```swift
let invocation = try await client.invoke(tool: "summarise", arguments: args)

let progressTask = Task {
    for await p in invocation.progress {
        if let pct = p.percent { print("  \(Int(pct))%") }
        if let msg = p.message { print(" ", msg) }
    }
}

// `outcome` is already set when `invoke` returns; the progress stream
// finishes alongside the terminal envelope.
_ = invocation.outcome
progressTask.cancel()
```

### Idempotency key

Retry safely by supplying the same idempotency key:

```swift
let key = IdempotencyKey("my-dedupe-key")
let invocation = try await client.invoke(
    tool: "process",
    arguments: args,
    idempotencyKey: key
)
```

If the runtime has already accepted an invocation with that key, it
returns the same `job_id` and queues no duplicate work
(see [`IdempotentRetry` sample](../../Samples/IdempotentRetry)).

## Job states

`JobState` (RFC §10):

```
accepted → queued → running ──▶ completed
                        ├────▶ failed
                        ├────▶ cancelled
                        ├────▶ blocked   (transient)
                        └────▶ paused    (transient)
```

State transitions are logged to the `EventLog`. Replay them via
`runtime.eventLog.replay(sessionId:after:)`.

## Cancellation

Cooperative: call `try await context.checkCancellation()` at safe
points in the handler. The client cancels with
`client.cancelJob(_:reason:deadlineMs:)`.

```swift
func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
    for chunk in bigDataSet {
        try await context.checkCancellation()   // throws ARCPError.cancelled
        process(chunk)
    }
    return .value(result)
}
```

```swift
try await client.cancelJob(jobId, reason: "user requested", deadlineMs: 5_000)
```

The [`Cancellation` sample](../../Samples/Cancellation) demonstrates
the full request/observe loop.

## Interrupts

An interrupt is a separate control signal; the runtime delivers
`job.interrupt` to the handler without changing the job's terminal
disposition. Different from cancellation — the job continues running
once the interrupt is observed. See `interrupt` capability flag in
`Capabilities` and the runtime's `handleInterrupt` path.

## Listing jobs

`session.list_jobs` (ARCP v1.1 §6.6) is exposed via the lower-level
`send`/`unhandled` API:

```swift
let requestId = MessageId.random()
try await client.send(
    Envelope(
        id: requestId,
        sessionId: client.info.sessionId,
        payload: .sessionListJobs(
            SessionListJobsPayload(limit: 50)
        )
    )
)

for await envelope in client.unhandled {
    guard envelope.correlationId == requestId,
          case .sessionJobs(let payload) = envelope.payload else { continue }
    for entry in payload.jobs {
        print(entry.jobId, entry.agent, entry.status)
    }
    break
}
```

See the [`ListJobs` sample](../../Samples/ListJobs).

## Heartbeats

The runtime emits `job.heartbeat` envelopes (carrying `sequence`,
`deadlineMs`, and `JobState`) automatically while a handler runs. The
default heartbeat interval is 30 seconds and is configurable on
`Capabilities.heartbeatIntervalSeconds`. If the runtime stops receiving
acks within the configured window it emits `HEARTBEAT_LOST` and
transitions the job to `failed`.

Handlers don't call a heartbeat method directly — keep the work
cooperative (`Task.yield()` inside CPU-bound loops) so the runtime's
heartbeat task gets time to publish.

See the [`Heartbeats` sample](../../Samples/Heartbeats).
