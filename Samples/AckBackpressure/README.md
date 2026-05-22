# AckBackpressure

**ARCP v1.1 §6.5 / §11.2 — acknowledgement-based flow control**

A high-frequency streaming agent emits 40 `stream.chunk` envelopes at 10 ms
intervals. The client acks slowly (every 10 chunks with a 200 ms delay). Once
the outbound buffer fills, the runtime autonomously sends a `backpressure`
envelope signalling the sender to reduce its emission rate.

## What it shows

| Feature | RFC section |
|---------|-------------|
| `context.openStream(kind:contentType:encoding:)` | §12.1 |
| `stream.sendText(_:sequence:)` | §12.2 |
| `stream.close(reason:)` | §12.3 |
| `backpressure` envelope with `desiredRatePerSecond` | §11.2 |
| Client `ack` envelope | §6.5 |
| `Capabilities(streaming: true)` | §5.1 |

## Running

```bash
swift run
```

## Expected output

```
→ tool.invoke sent
← job.accepted   job_id=xxxxxxxx
← stream.open    stream_id=xxxxxxxx
← backpressure   desired=N msg/s  M bytes remaining  reason=...
← stream.close   (chunks received: 40)
← job.completed  backpressure_observed=true
```
