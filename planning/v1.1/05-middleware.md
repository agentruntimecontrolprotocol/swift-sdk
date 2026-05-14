# 05 — Host adapters (middleware)

Mirrors TS [`typescript-sdk/packages/middleware/{node,express,fastify,hono,bun,otel}`](../../../typescript-sdk/packages/middleware/).
Adapter set chosen against the Swift server ecosystem: Vapor + Hummingbird
own the addressable market; everything else is either defunct or not
WebSocket-capable. Per BOOTSTRAP.md L165: "Reject hosts that are not in
active server-side Swift use."

The Swift TS-equivalence table:

| TS package                         | Swift target                | Rationale                                                                                   |
| ---------------------------------- | --------------------------- | ------------------------------------------------------------------------------------------- |
| `@arcp/node`                       | _(folded into `ARCPNIO`)_   | Node's `http.Server` is the framework-free seam. Swift's equivalent is raw `swift-nio`.     |
| `@arcp/express`                    | `ARCPVapor`                 | Vapor is Swift's mainstream batteries-included server.                                      |
| `@arcp/fastify`                    | _(folded into `ARCPVapor`)_ | Vapor covers fastify's "structured router + plugins" niche; second Vapor adapter not earnt. |
| `@arcp/hono`                       | `ARCPHummingbird`           | Hummingbird targets the lightweight/edge slot Hono occupies in TS.                          |
| `@arcp/bun`                        | _(no equivalent)_           | Bun's `Bun.serve` upgrade API has no Swift twin; rejected.                                  |
| `@arcp/middleware-otel`            | `ARCPOTel`                  | Cross-cutting `Transport` wrapper, host-agnostic — same shape as TS.                        |

---

## 1. `ARCPVapor`

Vapor adapter for [`vapor/vapor`](https://github.com/vapor/vapor) 4.x.

| Concern                       | Decision                                                                                                                                                                                                                          |
| ----------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| WS upgrade attach point       | `app.webSocket("/arcp") { req, ws in ... }` — Vapor's built-in WS router. Vapor's `WebSocket` type wraps `vapor/websocket-kit`, which `02-current-audit.md` §2.1 already lists as a current dep.                                  |
| Public surface                | `app.arcp.attach(server: ARCPServer, at: "/arcp", allowedHosts: [...])` — installed via a `StorageKey`-backed extension on `Application`, the idiomatic Vapor pattern (mirrors `app.jwt`, `app.queues`).                          |
| Host-header check             | Inspect `req.headers.first(name: .host)` before `req.webSocket {}`, return `Abort(.forbidden)` on mismatch. Default allowlist: `["localhost", "127.0.0.1"]` + configured `publicHost`. TS reference: `middleware/node/src/index.ts:81` `hostHeaderAllowed`. |
| Sendable bridge to SDK actor  | `WebSocket.onText`/`onBinary` are non-isolated closures; adapter wraps each frame in `Task { await transport.receive(frame) }` against an `actor VaporWSTransport: Transport` conforming to the §4 transport protocol from `04-architecture.md`. |
| Disconnect path               | Wire `WebSocket.onClose` (an `EventLoopFuture<Void>`) into the runtime's `Session.close` via `Task { await session.handleTransportClose() }`. Vapor will NOT cancel inflight `Task`s on disconnect; the adapter MUST.             |

Consumer-facing registration shape (illustration, not implementation):

```swift
// Sources/ARCPVapor/Application+ARCP.swift consumer call site
import Vapor
import ARCP
import ARCPVapor

app.arcp.attach(
    server: arcpServer,
    at: "/arcp",
    allowedHosts: ["localhost", "127.0.0.1", "agent.example.com"]
)
```

`app.arcp` storage holds the `ARCPServer` reference plus the allowlist; the
attach call registers the route and a teardown hook on `app.lifecycle`.

---

## 2. `ARCPHummingbird`

Hummingbird adapter for
[`hummingbird-project/hummingbird`](https://github.com/hummingbird-project/hummingbird)
2.x plus
[`hummingbird-project/hummingbird-websocket`](https://github.com/hummingbird-project/hummingbird-websocket)
(WS is a separate package in HB 2.x).

| Concern                       | Decision                                                                                                                                                                                                                          |
| ----------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| WS upgrade attach point       | `router.ws("/arcp") { request, ws in ... }` from `hummingbird-websocket`. HB 2.x uses `HBApplication.buildResponder()` + a WS-upgrade middleware; this differs from Vapor's router-attached model.                                |
| Public surface                | `router.arcp(at: "/arcp", server: arcpServer, allowedHosts: [...])` — Hummingbird routers prefer free-function-style extensions on `RouterMethods`, not `Application` storage. Distinct from Vapor's `app.arcp.attach`.            |
| Host-header check             | HB 2.x request: `request.head.headers[.host].first`. Reject with `HTTPResponse.Status.forbidden` before upgrading. Same default allowlist as Vapor.                                                                                |
| Sendable bridge to SDK actor  | HB 2.x WS handler is `async` already (`func handle(_ inbound: WebSocketInboundStream, _ outbound: WebSocketOutboundWriter) async`), so the bridge is a `for try await frame in inbound` loop driving the `Transport`. Cleaner than Vapor's callback shape. |
| Sub-protocol negotiation      | Spec §4 does NOT mandate a WS sub-protocol. HB's `WebSocketRouter` permits setting one; adapter ships a default of `nil` (matches §4) with an opt-in (`subProtocol: "arcp.v1"`) for ops-side routing. Vapor adapter mirrors this. |
| Disconnect path               | The `for try await` loop terminating closes the runtime session naturally — no explicit `onClose` wiring needed (unlike Vapor). The adapter MUST still cancel the per-session `Task` on loop exit so subscribers free. |

---

## 3. `ARCPOTel`

OpenTelemetry tracing wrapper. Mirrors
[`typescript-sdk/packages/middleware/otel/src/index.ts`](../../../typescript-sdk/packages/middleware/otel/src/index.ts)
verbatim — same span names, same attribute keys, same extension namespace.
Host-agnostic: wraps a `Transport`, not an HTTP server, so it composes
with `ARCPVapor` / `ARCPHummingbird` / `ARCPNIO` or with a `MemoryTransport`.

| Concern             | Decision                                                                                                                                                                                                                                                                                          |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Tracer dependency   | [`apple/swift-distributed-tracing`](https://github.com/apple/swift-distributed-tracing) for the `Tracer`/`Span` abstraction; exporter is `03-libraries.md`'s pick (`slashmo/swift-otel` or `open-telemetry/opentelemetry-swift`). `ARCPOTel` depends on swift-distributed-tracing only. |
| Span shape          | One span per envelope direction — `arcp.send <type>` (kind `.producer`) for outbound, `arcp.recv <type>` (kind `.consumer`) for inbound. Matches TS L73, L107.                                                                                                                                     |
| traceparent extract | TS extracts from `envelope.extensions["x-vendor.opentelemetry.tracecontext"]` (L48). Swift mirrors using `swift-distributed-tracing`'s `InstrumentationSystem.instrument.extract` against the same envelope-extensions carrier. No upgrade-request-header extraction — `04-architecture.md` `Transport` has no HTTP-request handle by then. |
| Attribute parity    | `arcp.direction`, `arcp.type`, `arcp.id`, `arcp.session_id`, `arcp.job_id`, `arcp.trace_id`, `arcp.event_seq`, `arcp.agent`, `arcp.lease.capabilities`. v1.1 adds `arcp.lease.expires_at` (from `payload.lease_constraints.expires_at`) and `arcp.budget.remaining` (JSON-encoded budget map). Names match TS L143–L182 exactly. |
| Extension namespace | `x-vendor.opentelemetry.tracecontext` — same constant as TS L48, conforms to spec §15 IANA namespace.                                                                                                                                                                                              |
| Composition         | `let traced = ARCPOTel.withTracing(transport, tracer: ...)` returns a `Transport`. Drop-in for `ARCPServer.accept(_:)` / `ARCPClient.connect(_:)`. Mirrors TS `withTracing` (L57).                                                                                                                |

---

## 4. `ARCPNIO`

Framework-free seam over
[`apple/swift-nio`](https://github.com/apple/swift-nio) +
[`apple/swift-nio-extras`](https://github.com/apple/swift-nio-extras) (for
the `NIOWebSocketServerUpgrader`). The Swift analogue of `@arcp/node` —
consumer brings their own `ServerBootstrap` + TLS pipeline.

**Verdict: ship it.** Two consumer profiles justify the seam:

1. Embedded server-side use where Vapor/Hummingbird are too much (lambda-style binaries, sidecars where the runtime budget is single-digit MB RSS).
2. Plug-into-existing-NIO-pipeline where the consumer already runs an
   HTTP/2 server (`swift-nio-http2`) and wants ARCP at one path.

Caveat to flag in the README: the consumer is on the hook for TLS
context (`NIOSSL.NIOSSLContext`), HTTP/1.1 upgrade plumbing
(`HTTPServerUpgradeHandler`), and any frontend authn — i.e. everything
Vapor/HB bundle. Deliberate trade-off, not a defect.

| Concern              | Decision                                                                                                                                                                                                                              |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| WS upgrade           | `NIOWebSocketServerUpgrader` from `swift-nio-extras`. Adapter publishes a `ChannelHandler` named `ARCPUpgradeHandler` consumers add to their pipeline.                                                                                  |
| Public surface       | `let upgrader = ARCPNIO.upgrader(server: arcpServer, path: "/arcp", allowedHosts: [...])` returning `NIOWebSocketServerUpgrader`. Consumer wires it into `HTTPServerUpgradeHandler.upgraders`.                                          |
| Host-header check    | Inside `shouldUpgrade` closure — return `nil` (rejects the upgrade) if `head.headers["host"]` is not in the allowlist. Reference: `middleware/node/src/index.ts:81`.                                                                  |
| Sendable bridge      | NIO channels are `EventLoop`-thread-bound, NOT actor-isolated. The adapter MUST hop with `Task { await ... }` and bridge `WebSocketFrame` reads via `NIOAsyncChannel`. Without `NIOAsyncChannel`, structured-concurrency cancellation does not flow through the pipeline; the adapter requires `swift-nio` 2.60+ for `NIOAsyncChannel`. |
| Disconnect path      | `NIOAsyncChannel.executeThenClose` finalizer terminates the per-session `Task`; the runtime session-close path runs in `defer`.                                                                                                       |

---

## 5. Hosts NOT to ship

| Host       | Status                                                                                                                            | Why not                                                                                                                                                                                                                |
| ---------- | --------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Kitura     | Defunct since IBM withdrew in 2020; last release Aug 2020.                                                                        | No active server-side Swift use. Adapter would rot before first release.                                                                                                                                              |
| Perfect    | Effectively defunct; last `PerfectHTTPServer` release predates Swift 5.5/async/await.                                             | Cannot drive `async`/`await` `Transport` without a thread-pool bridge no one will maintain.                                                                                                                            |
| Smoke      | Amazon's framework (`amzn/smoke-framework`); used inside AWS for a narrow tool set. No public WS story.                            | Niche, internal-leaning audience. If demanded, consumers can use `ARCPNIO` since Smoke also rides on `swift-nio`.                                                                                                      |
| AWS Lambda | Not a WebSocket-hosting framework.                                                                                                | The "WebSocket on API Gateway → Lambda" path runs through API Gateway's `$connect`/`$disconnect`/`$default` routes — that's a protocol-translation layer, not a transport. Belongs in ops/example territory if at all. |

---

## 6. SwiftPM target layout

Extends the `04-architecture.md` core/client/runtime split. Each adapter
is a separate library product so consumers opt in; per-adapter deps stay
out of `ARCPCore`/`ARCPClient`/`ARCPRuntime`.

```text
Sources/
  ARCPCore/           # envelopes, types, Transport protocol
  ARCPClient/
  ARCPRuntime/
  ARCPVapor/          # depends on vapor/vapor
  ARCPHummingbird/    # depends on hummingbird + hummingbird-websocket
  ARCPNIO/            # depends on swift-nio + swift-nio-extras
  ARCPOTel/           # depends on apple/swift-distributed-tracing
```

`Package.swift` products:

| Product           | Targets                          | Consumer pulls in                                                                                  |
| ----------------- | -------------------------------- | -------------------------------------------------------------------------------------------------- |
| `ARCP`            | `ARCPCore` + `ARCPClient`        | Client-only — no NIO, no Vapor, no HB.                                                             |
| `ARCPRuntime`     | + `ARCPRuntime`                  | Adds server core. Still no host framework.                                                         |
| `ARCPVapor`       | + `ARCPVapor`                    | Vapor + websocket-kit transitive.                                                                  |
| `ARCPHummingbird` | + `ARCPHummingbird`              | Hummingbird + hummingbird-websocket transitive.                                                    |
| `ARCPNIO`         | + `ARCPNIO`                      | swift-nio + swift-nio-extras transitive (no host framework).                                       |
| `ARCPOTel`        | + `ARCPOTel`                     | swift-distributed-tracing transitive; exporter is the consumer's choice.                           |

Per-target deps declared at `.target(dependencies: [...])`, never at the
core. Crucially, `ARCPCore` does NOT depend on `swift-nio` — the current
SDK's transitive NIO pull-in (`02-current-audit.md` §2.1) goes away once
NIO is contained to `ARCPNIO`/`ARCPVapor`/`ARCPHummingbird`.

---

## 7. Risks worth flagging

| Risk                                       | Specific Swift concern                                                                                                                                                                                                                                                                                  | Mitigation                                                                                                                                          |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Vapor `WebSocket.onText` non-isolated      | `onText`/`onBinary` callbacks run on the NIO `EventLoop`. Bridging to the SDK's session actor requires `Task { await ... }`. Vapor disconnects do NOT cancel that `Task` — the adapter MUST wire `WebSocket.onClose` (an `EventLoopFuture<Void>`) into the runtime's session-close path explicitly.       | `VaporWSTransport` owns a `Task` per session and `cancel()`s on `onClose` fulfillment. Tested via `MemoryTransport`-backed integration in 07-tests. |
| Hummingbird WS = separate package          | `hummingbird-websocket` versions independently from `hummingbird`. The adapter `Package.swift` MUST pin both with compatible ranges and document the supported HB 2.x window. HB 1.x is API-incompatible — adapter is HB 2.x-only.                                                                       | Pin `hummingbird` `from: "2.0.0"`, `hummingbird-websocket` `from: "2.0.0"` in the `ARCPHummingbird` target only; document floor.                    |
| Sub-protocol semantics                     | Spec §4 doesn't mandate a sub-protocol. Both Vapor and HB allow setting one. If an operator sets `Sec-WebSocket-Protocol: arcp.v1` on a load balancer for routing, the upgrader MUST echo it back or browsers reject. The adapter ships `subProtocol: nil` default, opt-in `arcp.v1`.                     | Test both modes; document the deploy-time gotcha in 08-docs-readme.                                                                                  |
| ARCPNIO consumer-borne TLS                 | Consumer wires `NIOSSL.NIOSSLContext` themselves. A consumer who skips TLS ends up running ARCP over plaintext WS. Spec §4 mandates `wss://` for network deployments.                                                                                                                                    | README quickstart MUST show `NIOSSLContext` setup; CI sample MUST refuse to start without TLS unless `ARCP_INSECURE=1` is set.                       |
| Host-header allowlist default              | TS allows `undefined` allowlist = no check (`middleware/node/src/index.ts:85`). For ARCP — where every transport carries privileged session/job operations — Swift adapter SHOULD default to `["localhost", "127.0.0.1"]` rather than "off". Tighter than TS by design; documented in 08-docs-readme.    | Type the option as `[String]` (non-optional) with the default supplied at the `attach` call site.                                                    |
| Heartbeat amplification (spec §14)         | Spec §14 warns: a client opening many sessions and sending only heartbeats can exhaust runtime resources. The host adapter — not the SDK core — is the right layer to enforce per-IP / per-principal session caps because that's where the upgrade request lives.                                       | Vapor + HB adapters expose `sessionCap: per(principal: Int)`; reject with HTTP 429 on upgrade. Counter lives in `ARCPServer`, queried during upgrade. |
| Cross-session subscription audit (§14)     | Spec §14 SHOULDs an audit log entry per `job.subscribe` with subscriber principal, target job, target principal, policy decision. This is a runtime concern (the upgrade adapter doesn't see subscribes), but `ARCPOTel` is where the span attributes land for export to an audit sink.                  | `ARCPOTel` adds `arcp.subscription.target_principal` attribute on `arcp.recv job.subscribe` spans; downstream sink filters on `arcp.type=job.subscribe`. |
| `ARCPOTel` traceparent on upgrade request  | Spec §11 + TS `middleware-otel` extracts trace context from envelope extensions (`x-vendor.opentelemetry.tracecontext`), NOT from upgrade-request headers. A consumer expecting `traceparent` HTTP header propagation to seed the session span will be surprised.                                       | Document explicitly; if upgrade-header propagation is wanted, that's a host-adapter feature (Vapor middleware injecting the carrier into the first envelope), not OTel-wrapper feature. |

---

## 8. Out of scope for the v1.1 middleware milestone

- Authentication middleware. `ARCPCore` carries the bearer token in
  `session.hello.payload.auth.token` per §6.1. Host adapters do not
  introspect tokens — that's `ARCPRuntime`'s concern.
- HTTP/2 multiplexed transport. Spec §4 lists HTTP/2 as optional; no TS
  reference implementation exists yet; adding it through `ARCPNIO` later
  is straightforward since `swift-nio-http2` is in the same family.
- Hook for v1.0-only fallback transports. v1.1 is wire-compatible with
  v1.0 clients per §6.2 negotiation (handled in `ARCPCore`); no adapter
  work needed.
