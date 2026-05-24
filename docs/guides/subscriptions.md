# Subscriptions

A subscription is a live event feed. The client declares a filter; the
runtime wraps every matching envelope in a `subscribe.event` payload
and pushes it down the session (RFC §13).

## Subscribing (client)

Send a `subscribe` envelope and read `subscribe.event` envelopes from
`client.unhandled`:

```swift
// All envelopes in the session
try await client.send(
    Envelope(
        sessionId: client.info.sessionId,
        payload: .subscribe(
            SubscribePayload(filter: SubscriptionFilter())
        )
    )
)
```

Filter on specific jobs:

```swift
let filter = SubscriptionFilter(jobIds: [myJobId])
try await client.send(
    Envelope(
        sessionId: client.info.sessionId,
        payload: .subscribe(SubscribePayload(filter: filter))
    )
)
```

Backfill from a known message id, then receive live events:

```swift
let since = SubscriptionSince(afterMessageId: lastSeenId)
try await client.send(
    Envelope(
        sessionId: client.info.sessionId,
        payload: .subscribe(
            SubscribePayload(filter: SubscriptionFilter(), since: since)
        )
    )
)
```

After backfill completes the runtime emits a synthetic
`subscribe.event` with name `subscription.backfill_complete`:

```swift
for await envelope in client.unhandled {
    if case .eventEmit(let payload) = envelope.payload,
       payload.name == "subscription.backfill_complete" {
        print("now live")
        continue
    }
    if case .subscribeEvent(let event) = envelope.payload {
        handle(event.event)
    }
}
```

## SubscriptionFilter fields

| Field | Type | Description |
|-------|------|-------------|
| `sessionIds` | `[SessionId]?` | Restrict to specific session ids |
| `traceIds` | `[TraceId]?` | Match envelopes carrying these trace ids |
| `jobIds` | `[JobId]?` | One or more job ids |
| `streamIds` | `[StreamId]?` | One or more stream ids |
| `types` | `[String]?` | Wire-type names, e.g. `"log"`, `"job.progress"` |
| `minPriority` | `Priority?` | Drop envelopes below this priority |

All fields are AND-ed together; within a field the match is an OR. An
empty `SubscriptionFilter()` matches every envelope the session
emits.

## Cancelling a subscription

The runtime returns `subscribe.accepted` carrying a `SubscriptionId`;
keep it to cancel later:

```swift
try await client.send(
    Envelope(
        sessionId: client.info.sessionId,
        payload: .unsubscribe(UnsubscribePayload(subscriptionId: id))
    )
)
```

## Server-side subscription routing

`SubscriptionManager` is an actor inside `ARCPRuntime`. Every envelope
that flows out of the runtime is routed through
`subscriptionManager.route(envelope:)`. Matching envelopes are wrapped
in `subscribe.event` and delivered to the subscriber's transport.

Backfill runs in a child `Task`, scanning the `EventLog` for historical
matches and emitting them before switching to live routing. A synthetic
`subscription.backfill_complete` `subscribe.event` marks the end of historical
data.

## Multiple subscribers

A single session supports multiple concurrent subscriptions — each with
its own filter and an independent `SubscriptionId`. The
[`Subscriptions` sample](../../Samples/Subscriptions) demonstrates
three observers on one session with three different filters.
