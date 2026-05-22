# Tracing

**ARCP v1.1 §10.3 / §17.1 — distributed trace context propagation**

Every ARCP envelope carries first-class trace fields (`traceId`, `spanId`,
`parentSpanId`) and an `extensions` map for W3C `traceparent` injection.
This sample shows the full propagation lifecycle from root context creation
through span export.

## What it shows

| Feature | RFC section |
|---------|-------------|
| `TraceContext.newTrace()` — create root trace | §10.3 |
| `rootCtx.childSpan()` — derive child span | §10.3 |
| `Tracing.withTrace(_:)` — Swift task-local propagation | §10.3 |
| Stamping `Envelope` with `traceId`/`spanId`/`parentSpanId` | §10.3 |
| W3C `traceparent` in `Envelope.extensions` | §10.3 |
| Agent reads `invocation.traceId` for downstream calls | §10.3 |
| Client emits `trace.span` envelope as exporter | §17.1 |
| `TraceSpanPayload(name:startedAt:endedAt:attributes:status:)` | §17.1 |

## Trace hierarchy

```
rootCtx  (newTrace)
  └── invokeCtx  (childSpan)   ← stamped on tool.invoke envelope
        └── agent phases 1 & 2 (logged via context.log)
              └── client span  (trace.span envelope after job.completed)
```

## Running

```bash
swift run
```

## Expected output

```
root  trace_id=<128-bit>  span_id=<64-bit>
child trace_id=<128-bit>  span_id=<64-bit>  parent=<64-bit>
→ tool.invoke sent  traceparent=00-<traceId>-<spanId>-01
← job.accepted   job_id=xxxxxxxx  trace=xxxxxxxx
← log[info]      trace propagated  trace_id=...
← log[info]      phase 1: fetch
← log[info]      phase 2: transform
← job.completed  result=traced result  trace=xxxxxxxx
→ trace.span emitted  name=client.tool_invoke  latency=Nms
```

## Production integration

Replace the `trace.span` emission block with an OTLP exporter that forwards
spans to Jaeger, Zipkin, or any OpenTelemetry-compatible backend. The W3C
`traceparent` in `extensions` lets the agent propagate the trace into any
downstream HTTP or gRPC call without ARCP-specific coupling.
