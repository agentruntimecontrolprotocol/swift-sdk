# Recipe: Multi-Agent Budget

**ARCP v1.1 §17.3.1 / §18.3 — cost-budget enforcement across serial worker steps**

A planner agent fans out to three worker steps serially. Each worker charges
`$0.20` via `context.charge`. The job carries a `$0.50` USD cap, so workers 1
and 2 succeed and worker 3 is skipped — `ARCPError.budgetExhausted` is caught
cleanly and the job completes with a partial result.

## What it shows

| Feature | RFC section |
|---------|-------------|
| `CostBudget.from(["USD": 0.50])` on `ToolInvokePayload` | §17.3.1 |
| `context.budget.remaining(for:)` — inspect remaining budget | §17.3.1 |
| `context.charge(name:amount:currency:)` — deduct per worker | §18.3 |
| `ARCPError.budgetExhausted(detail:)` — caught, not fatal | §17.3.1 |
| `Capabilities(costBudget: true)` on both runtime and client | §17.3.1 |

## Run

```bash
cd Recipes/multi-agent-budget && swift run
```

## Expected output

```
── multi-agent cost budget: $0.50 cap, 3 workers at $0.20 each ──
→ multi.planner submitted (budget=USD 0.50)
← job.accepted  job_id=xxxxxxxx
← log[info]  planner: fanning out to 3 workers (budget=$0.50, $0.20/worker)
← log[info]  worker 1: starting
← log[info]  worker 1: budget remaining = $0.50
← log[info]  worker 1: completed
← log[info]  worker 2: starting
← log[info]  worker 2: budget remaining = $0.30
← log[info]  worker 2: completed
← log[info]  worker 3: starting
← log[info]  worker 3: budget remaining = $0.10
← log[warning]  worker 3: budget exhausted — skipping
← log[info]  planner: done (completed=2 skipped=1)
← job.completed  completed=2  skipped=1
```

## Key files

| File | What it shows |
|------|---------------|
| `Sources/MultiAgentBudget/main.swift` | End-to-end wiring |
| `PlannerAgent` | Serial fan-out with `budgetExhausted` guard |
| `runWorkerStep` | `budget.remaining` + `context.charge` pattern |

## Related samples

- [SubmitAndStream](../../Samples/SubmitAndStream) — basic job lifecycle
- [Leases](../../Samples/Leases) — lease-gated shell agent
- [Capability-Negotiation](../../Samples/Capability-Negotiation) — `cost.usd` rollups
