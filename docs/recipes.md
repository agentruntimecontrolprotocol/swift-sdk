# Recipes

Ready-to-run examples that demonstrate common integration patterns. Each
recipe is a self-contained Swift package under [`Recipes/`](../Recipes).

## Email vendor leases

**Directory:** `Recipes/email-vendor-leases`

Demonstrates issuing and validating vendor-scoped leases — the pattern used
when a third-party orchestrator calls your agent but you need to constrain
which resources it can touch.

Key concepts:
- `LeaseConstraints` with `expiresAt`, `costBudget`, and `modelUse` fields
- `CredentialProvisioner` issuing scoped SMTP credentials
- Lease expiry check inside a long-running `ToolHandler`
- `LEASE_EXPIRED` error propagation back to the caller

See [`Recipes/email-vendor-leases/README.md`](../Recipes/email-vendor-leases/README.md).

## MCP skill

**Directory:** `Recipes/mcp-skill`

Shows how to wrap an existing MCP (Model Context Protocol) tool as an ARCP
`ToolHandler` so it can participate in durable jobs with heartbeats, cost
tracking, and permission challenges.

Key concepts:
- `ToolHandler` adapter pattern
- Forwarding `JobContext.heartbeat()` across the MCP boundary
- Mapping MCP errors to `ARCPError` / `ErrorCode`
- `MemoryTransport` for unit-testing the adapter

See [`Recipes/mcp-skill/README.md`](../Recipes/mcp-skill/README.md).

## Multi-agent budget

**Directory:** `Recipes/multi-agent-budget`

A two-agent pipeline where a coordinator delegates sub-tasks to a worker,
each sub-task has a cost budget, and the coordinator aggregates results.
Illustrates the spending lifecycle from submission to `BUDGET_EXHAUSTED`
back-pressure.

Key concepts:
- `agent.delegate` / `agent.handoff` envelopes
- Per-job `cost.budget` tracking with `JobContext.charge(_:)`
- `BudgetTracker` metric emission
- Coordinator-side aggregation and re-submission on partial failure

See [`Recipes/multi-agent-budget/README.md`](../Recipes/multi-agent-budget/README.md).

## Stream resume

**Directory:** `Recipes/stream-resume`

Demonstrates a resilient streaming handler: the consumer disconnects
mid-stream, reconnects with `after_message_id`, and the runtime replays
missed chunks from the SQLite event log.

Key concepts:
- `StreamHandle` open / send / close lifecycle
- `EventLog` replay via `after_message_id`
- `backfill_complete` boundary detection
- Artifact retention and `ArtifactStore` sweep

See [`Recipes/stream-resume/README.md`](../Recipes/stream-resume/README.md).

---

For the full sample library (27 examples covering individual primitives),
see [`Samples/README.md`](../Samples/README.md).
