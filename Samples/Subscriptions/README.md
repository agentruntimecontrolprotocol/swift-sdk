# Subscriptions

One producing session, three Observer clients, three different sinks.
None of them ever issue a command.

## Before ARCP

Most teams sidecar the agent with a tee: agent emits to stdout, a
shipper tails the log, a second tail re-parses for metrics, a third
process writes to SQLite for replay. Three pipelines diverge over time,
none of them know about each other, and adding a fourth consumer means
another sidecar.

## With ARCP

```swift
let client: ARCPClient = .placeholder            // observer client
let subId = try await subscribe(client, sessionId: target, types: ["metric"])
for await env in client.unhandled {
    if let inner = unwrapEvent(env) {
        await sink.handle(inner)
    }
}
```

Three observers. One transport each. Filters declared inline. The agent
never knows they exist.

## ARCP primitives

- Subscriptions, filters, Observer role — RFC §13, §5.
- `since.after_message_id` backfill + the synthetic
  `subscription.backfill_complete` marker — §13.3.
- Standard metrics + trace spans — §17.
- Stream-kind filtering for `kind: thought` redaction — §11.4.

## File tour

- `Sources/Subscriptions/main.swift` — boots three clients in a `TaskGroup`.
- `Sources/Subscriptions/Sinks.swift` — `StdoutSink`, `SQLiteSink`,
  `OTLPSink`, plus the `ARCPClient.placeholder` setup elision.

## Variations

- Replace SQLite with ClickHouse for fleet-wide replay.
- Tee stdout into Slack via a `min_priority: critical` filter.
- A fourth subscriber on `kind: thought` only, gated by stricter
  access control.
