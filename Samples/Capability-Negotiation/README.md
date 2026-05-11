# Capability-Negotiation

LiteLLM-style router selecting peer model-serving runtimes by their
advertised capabilities (cost, latency, model class), with ordered
fallback on `RESOURCE_EXHAUSTED` / `UNAVAILABLE`. Cost rolls up via the
standard `cost.usd` metric.

## Before ARCP

Static `model -> provider` map in YAML. Cost / latency tracked in a
separate per-provider sidecar dashboard. The router has no idea which
provider 429s right now, so retries spray across already-saturated
endpoints. Per-tenant cost reporting requires a third pipeline.

## With ARCP

```swift
profiles[name] = profile(from: c.info.negotiatedCapabilities)
let chain = candidateChain(profiles, requestClass: "balanced")
let reply = try await invokeWithFallback(
    clients: clients, chain: chain,
    tool: "chat.completion",
    arguments: .object([...]),
    traceId: traceId
)
```

Peer selection is data-driven from the negotiated capabilities — no
sidecar config. Per-call cost lands on the meter via `cost.usd` metrics,
keyed by tenant + peer.

## ARCP primitives

- Capability extensions on the session — RFC §7, §21.
- `tool.invoke` / `tool.error` — §6.3.
- Canonical retry classification — §18.3.
- Standard metric names (`tokens.used`, `cost.usd`) — §17.3.1.
- Envelope `extensions` for per-call routing context — §6.1.

## File tour

- `Sources/CapabilityNegotiation/main.swift` — open all peers, route
  one request, print rollup. `invokeWithFallback` walks the chain.
- `Sources/CapabilityNegotiation/Setup.swift` — `ARCPClient.placeholder`.

## Variations

- Push fallback chains to a remote policy service.
- Add a `quality` axis (offline eval scores) and weight selection.
- Re-emit the chosen peer + cost back to a billing topic for per-call
  chargeback.
