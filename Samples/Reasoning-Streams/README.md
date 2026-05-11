# Reasoning-Streams

A primary agent emits its reasoning as a `kind: thought` stream. A
mirror peer runtime subscribes, runs a smaller critic model on each
thought, and delegates `arcpx.mirror.critique.v1` events back into the
primary's session. Bounded by a token budget — when spent, the mirror
unsubscribes and the primary continues without critique.

## Before ARCP

Self-critique loops drift: there's no clean way to (a) expose just the
reasoning to a separate process for a second opinion, (b) cap the
rounds, (c) gracefully step back when the critic budget is spent.

## With ARCP

```swift
// mirror peer subscribes to the primary's thought stream...
let subId = try await subscribeThoughts(mirror, target: primary.info.sessionId)

// ...and delegates critiques back as namespaced events.
try await mirror.send(Envelope(
    sessionId: mirror.info.sessionId,
    payload: .unknown(typeName: "agent.delegate", payload: .object([...]))
))
```

The mirror is a *peer runtime* (`agentHandoff: true`,
`subscriptions: true`, `trustLevel: trusted`), not an Observer — it
both reads and writes back into the primary's session.

## ARCP primitives

- `kind: thought` reasoning streams — RFC §11.4.
- Subscriptions with type filter — §13.2.
- Custom extension event under `arcpx.<domain>.<name>.v<n>` — §21.1.
- `agent.delegate` for cross-runtime delivery — §14.
- `tokens.used` budget — §17.3.1.

## File tour

- `Sources/ReasoningStreams/main.swift` — boots primary + mirror,
  routes critiques back into the primary's loop.
- `Sources/ReasoningStreams/Agents.swift` — `primaryStep`,
  `critiqueThought`, `withTimeout`, `ARCPClient.placeholder`.

## Variations

- Multiple mirrors (security / factuality / style) subscribed in
  parallel; primary merges critiques by severity.
- Persist critiques to the SQLite sink in Subscriptions for drift
  analysis.
- Replace the critic LLM with a deterministic verifier (linter, type
  checker) that returns `severity` from a rule set.
