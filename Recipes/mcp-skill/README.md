# Recipe: MCP Skill

**ARCP v1.1 §20 / §15.4 / §10 / §18.3 — bridging an MCP tool as an ARCP ToolHandler**

An `MCPToolAdapter` wraps any MCP (Model Context Protocol) tool as an ARCP
`ToolHandler`, bridging `tool.invoke` to an MCP `call_tool` RPC. The adapter
adds lease-expiry checking, cooperative cancellation, per-token cost tracking,
and structured observability — capabilities MCP alone does not provide.

Replace the `MCPStub` with a real MCP SDK client (e.g.
`modelcontextprotocol/swift-sdk`) wired over stdio or SSE for production.

## What it shows

| Feature | RFC section |
|---------|-------------|
| `MCPToolAdapter: ToolHandler` — adapter pattern for MCP interop | §20 |
| `context.checkLeaseExpiration()` — fail fast if lease has expired | §15.4 |
| `context.checkCancellation()` — cooperative cancel before blocking I/O | §10 |
| `context.charge(name:amount:currency:)` — per-token USD cost deduction | §18.3 |
| `context.metric(name:value:unit:dims:)` — token-count observability | §17.3 |
| `context.log(level:message:attributes:)` — structured job logging | §17.2 |
| Two tools registered: `web_search` and `code_execute` | §20 |

## Run

```bash
cd Recipes/mcp-skill && swift run
```

## Expected output

```
── ARCP → MCP bridge: tool.invoke → call_tool → job.completed ──
→ web_search submitted
← job.accepted  job_id=xxxxxxxx
← log[info]  forwarding to MCP tool: web_search
← metric  mcp.token_count=42.0 tokens
← log[info]  MCP returned 42 tokens: Top results from MCP tool 'web_search': [1] ARCP spec §1, [2] ARCP SDK docs
← job.completed
   content=Top results from MCP tool 'web_search': [1] ARCP spec §1, [2] ARCP SDK docs
   token_count=42
```

## How the adapter works

`MCPToolAdapter` conforms to `ToolHandler` and holds an `MCPStub` (or real MCP
client). On each invocation it:

1. Calls `checkLeaseExpiration()` — synchronous fail-fast before any I/O
2. Calls `checkCancellation()` — honours a pending `cancel` or `interrupt`
3. Forwards `invocation.arguments` to the MCP `call_tool` RPC
4. Calls `charge(name:amount:currency:)` to deduct per-token cost from the budget
5. Emits a `metric` event so the client can observe token throughput

## Key files

| File | What it shows |
|------|---------------|
| `Sources/MCPSkill/main.swift` | End-to-end wiring |
| `MCPStub` | Simulated MCP client — replace with real transport |
| `MCPToolAdapter` | `ToolHandler` with lease + cancel + charge + metric + log |

## Related samples

- [Leases](../../Samples/Leases) — `checkLeaseExpiration()` and lease-gated tools
- [Cancellation](../../Samples/Cancellation) — cooperative `checkCancellation()` pattern
- [BudgetTracking](../../Samples/BudgetTracking) — `charge` and `BUDGET_EXHAUSTED`
- [Observability](../../Samples/Observability) — structured log + metric events
