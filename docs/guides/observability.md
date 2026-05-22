# Observability

ARCP provides structured telemetry at three levels: log events, metric
events, and distributed traces (RFC §17).

## Logging

Emit structured log lines from a handler:

```swift
try await context.log(level: .info, message: "Processing item 1 of 42", attributes: nil)
try await context.log(
    level: .warning,
    message: "upstream rate limit",
    attributes: [
        "retry_after": .int(5),
        "endpoint":    .string("/v1/completions"),
    ]
)
```

Log levels: `.debug`, `.info`, `.warning`, `.error`.

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
`context.charge(…)` call (see [Leases](leases.md)).

## Distributed tracing

ARCP envelopes carry an optional `traceId` (W3C trace ID format). The
runtime propagates it to all child jobs via `TraceContext`.

```swift
import ARCP

// Pass a W3C traceparent from an HTTP request
let traceCtx = TraceContext(traceParent: request.headers["traceparent"])

let (outcome, _) = try await client.invoke(
    tool: "summarise",
    arguments: args,
    traceId: traceCtx.traceId
)
```

To export spans to a collector, subscribe to `metric` envelopes and
look for the `trace.span` type, or use the
[`Tracing` sample](../../Samples/Tracing) as a starting point.

## Event log

All envelopes — handshake, job lifecycle, streams, logs, metrics — are
stored in an SQLite `EventLog`. Query it for post-mortem analysis:

```swift
let envelopes = try await runtime.eventLog.query(sessionId: sessId)
for env in envelopes { print(env.type, env.id) }
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
// … then create ARCPRuntime …
```
