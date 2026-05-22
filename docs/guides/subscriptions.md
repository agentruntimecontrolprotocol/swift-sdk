# Subscriptions

A subscription is a live event feed. The client declares a filter;
the runtime pushes every matching envelope to the subscriber as a
`subscribe.event` message (RFC §13).

## Subscribing (client)

```swift
// All events
let sub = try await client.subscribe(filter: .all, since: nil)

// Only job events for a specific job
let sub = try await client.subscribe(
    filter: .jobId(myJobId),
    since: nil
)

// Backfill from 10 minutes ago, then live
let since = SubscriptionSince.timestamp(Date().addingTimeInterval(-600))
let sub = try await client.subscribe(filter: .all, since: since)
```

The subscription delivers a `boundary` event
(`subscription.backfill_complete`) after historical events are flushed
and before live events begin:

```swift
for await event in sub.events {
    if case .subscriptionBackfillComplete = event.payload {
        print("now live")
        continue
    }
    handle(event)
}
```

## Filter types

| Filter | Description |
|--------|-------------|
| `.all` | Every envelope in the session |
| `.jobId(JobId)` | Events for one job |
| `.messageType(String)` | Envelopes of a specific wire type |
| `.sessionId(SessionId)` | Events from a specific session |

## Cancelling a subscription

```swift
sub.cancel()   // sends subscribe.cancel, stops the AsyncStream
```

## Server-side subscription routing

`SubscriptionManager` is an actor inside `ARCPRuntime`. Every envelope
that flows out of the runtime is routed through
`subscriptionManager.route(envelope:)`. Matching envelopes are wrapped
in `subscribe.event` and delivered to the subscriber's transport.

Backfill runs in a child `Task`, scanning the `EventLog` for historical
matches and emitting them before switching to live routing. A synthetic
`subscription.backfill_complete` boundary marks the end of historical
data.

## Multiple subscribers

A single session supports multiple concurrent subscriptions — each with
its own filter and independent `AsyncStream`. The
[`Subscriptions` sample](../../Samples/Subscriptions) demonstrates three
observers on one session with three different filters.
