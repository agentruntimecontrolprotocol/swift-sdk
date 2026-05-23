# Observability

ARCP provides structured telemetry at three levels: log events, metric
events, and distributed traces (RFC §17).

## Logging

Emit structured log lines from a handler:

```swift
try await context.log(level: .info, message: "Processing item 1 of 42", attributes: nil)
try await context.log(
    level: .warn,
    message: "upstream rate limit",
    attributes: [
        "retry_after": .int(5),
        "endpoint":    .string("/v1/completions"),
    ]
)
```

Log levels: `.trace`, `.debug`, `.info`, `.warn`, `.error`, `.critical`.

Each `log` call emits a `log` envelope stored in the `EventLog` and
routed to any matching subscribers.

## Metrics

Emit numeric samples with optional unit and dimensions:

```swift
try await context.metric(
    name: "tokens.processed",
    value: 1024,
    unit: "count",
    dims: nil
)
try await context.metric(
    name: "latency.llm",
    value: 0.312,
    unit: "s",
    dims: ["model": .string("gpt-4o"), "region": .string("us-east-1")]
)
```

The `cost.budget.remaining` metric is emitted automatically after each
`context.charge(...)` call (see [Leases](leases.md)).

## Distributed tracing

ARCP envelopes carry `traceId`, `spanId`, and `parentSpanId` fields.
The runtime preserves whatever the inbound envelope carries; to set a
trace context for outbound work, scope the call with
`Tracing.withTrace { ... }`:

```swift
import ARCP

let trace = TraceContext.newTrace()
let invocation = try await Tracing.withTrace(trace) {
    try await client.invoke(
        tool: "summarise",
        arguments: args
    )
}
```

`Tracing.current` is task-local, so all envelopes built inside the
closure inherit the trace automatically. Child spans:

```swift
let child = trace.childSpan()
try await Tracing.withTrace(child) { ... }
```

The W3C `traceparent` representation can be reconstructed from
`TraceContext.traceId` and `TraceContext.spanId` at the integration
boundary.

## Event log

All envelopes — handshake, job lifecycle, streams, logs, metrics — are
stored in an SQLite `EventLog`. Replay envelopes for a session, optionally
from a specific message id:

```swift
let envelopes = try await runtime.eventLog.replay(sessionId: sessionId, after: nil)
for env in envelopes { print(env.payload.typeName, env.id) }
```

Or replay a session from the CLI:

```bash
swift run arcp replay events.sqlite sess_01JXXX
```

## swift-log integration

`ARCPRuntime` uses the
[swift-log](https://github.com/apple/swift-log) API internally. Inject
a `LoggingSystem` bootstrap at startup to route ARCP internal logs to
your log aggregator:

```swift
import Logging

LoggingSystem.bootstrap(MyLogHandler.init)
// ... then create ARCPRuntime ...
```

See the [`Tracing` sample](../../Samples/Tracing) for an end-to-end
example.
