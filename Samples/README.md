# ARCP Swift Samples

The numbered samples under `01-…` through `06-…` are the original
walkthrough series. The fourteen named samples below are per-primitive
illustrations — one for each ARCP capability defined in RFC-0001 v2,
mirroring the canonical `python-sdk/examples/` set.

> **Illustrative, not runnable.** Each sample imports `ARCP` as the
> public Swift package. Setup boilerplate (transport URL, identity,
> auth) is elided behind `ARCPClient.placeholder` or a `fatalError`
> stub. LLM and framework calls live in tiny stub files so the
> protocol code in `main.swift` is what you read.

## The fourteen

| Directory                            | Demonstrates                                                                       | Spec               |
|--------------------------------------|------------------------------------------------------------------------------------|--------------------|
| [`Subscriptions/`](./Subscriptions)                       | Three Observer clients on one session, three filters, three sinks.                 | §5, §13            |
| [`Leases/`](./Leases)                                     | Lease-gated shell agent. Read leases coarse, write leases scoped.                  | §15.4–§15.5        |
| [`Lease-Revocation/`](./Lease-Revocation)                 | Per-table leases with `lease.revoked` / `lease.extended` mid-flight.               | §15.5              |
| [`Permission-Challenge/`](./Permission-Challenge)         | Two-party permission challenge — generator asks, reviewer holds veto.              | §15.4, §6.4        |
| [`Delegation/`](./Delegation)                             | `agent.delegate` fan-out + `JobMux` to demux events by `job_id`.                   | §14, §6.4          |
| [`Handoff/`](./Handoff)                                   | `agent.handoff` with transcript packed as artifact, runtime fingerprint pinned.    | §14, §16, §8.3     |
| [`Heartbeats/`](./Heartbeats)                             | Worker federation; heartbeat-loss reroute via `IdempotencyKey`.                    | §10.3, §6.4        |
| [`Capability-Negotiation/`](./Capability-Negotiation)     | Capability-driven peer routing; standard `cost.usd` rollups.                       | §7, §17.3.1, §18.3 |
| [`Resumability/`](./Resumability)                         | **Actually crash and resume.** `exit(137)` mid-flight; second invocation resumes.  | §10, §19, §6.4     |
| [`Reasoning-Streams/`](./Reasoning-Streams)               | `kind: thought` stream + a peer runtime that subscribes and delegates critiques.   | §11.4, §13, §14    |
| [`Extensions/`](./Extensions)                             | Custom `arcpx.sdr.*.v1` extension namespace with correct unknown-message handling. | §21                |
| [`Human-Input/`](./Human-Input)                           | `human.input.request` fanned across phone/email/Slack; first-wins resolution.      | §12                |
| [`Cancellation/`](./Cancellation)                         | Cooperative `cancel` (terminate) vs `interrupt` (pause and ask).                   | §10.4–§10.5        |
| [`MCP/`](./MCP)                                           | ARCP runtime fronting an MCP server: `tool.invoke` → MCP `call_tool`.              | §20                |

## Conventions

- Swift 6 / async-await throughout. `AsyncSequence` for event loops,
  structured concurrency (`async let`, `TaskGroup`) for fan-out,
  actors for shared state, value-semantic structs for payloads.
- Each sample is its own `Package.swift` with a single executable
  target, depending on the root `ARCP` package via path. Run with:
  ```bash
  cd Samples/Subscriptions && swift build
  ```
- One `main.swift` (the protocol code) + 0–2 sibling stub files named
  for what they elide (`Sinks.swift`, `Agents.swift`, `Steps.swift`,
  `Channels.swift`, etc.).
- `ARCPClient.placeholder` literally — transport, identity, and auth
  are setup noise, not the point.
- Envelopes match RFC-0001 v2 exactly. Custom message types follow
  §21.1 `arcpx.<domain>.<name>.v<n>` naming and ride as
  `MessageType.unknown` envelopes when the SDK has no typed payload yet.

## Reading order

For a brisk tour: `Subscriptions`, `Leases`, `Delegation`,
`Resumability` (this one actually crashes and recovers), `Cancellation`,
`Extensions`, `MCP`. These seven exercise the bulk of the protocol.
