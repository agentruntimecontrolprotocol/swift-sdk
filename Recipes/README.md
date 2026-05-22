# ARCP Swift SDK — Recipes

Targeted, runnable examples that each demonstrate one ARCP v1.1 feature in
isolation. Every recipe is a self-contained Swift package; run it with
`swift run` from its directory.

For broader end-to-end scenarios see [`Samples/`](../Samples/).

## Recipes

| Recipe | What it demonstrates | Key spec sections |
|--------|----------------------|-------------------|
| [email-vendor-leases](email-vendor-leases/) | `requestPermission` + `PermissionHandler` veto | §15.4, §6.4 |
| [mcp-skill](mcp-skill/) | Wrapping an MCP `call_tool` as an ARCP `ToolHandler` | §20, §15.4, §10, §18.3 |
| [multi-agent-budget](multi-agent-budget/) | Cost-budget cap across serial worker steps | §17.3.1, §18.3 |
| [stream-resume](stream-resume/) | Crash-and-resume for streamed `ResultChunkStream` | §10, §19, §7.2 |

## Running a recipe

```bash
cd Recipes/<name>
swift run
```

Each recipe prints its own annotated output and exits. No server or external
dependency is required — all recipes use `MemoryTransport`.

## Writing your own

1. Copy any recipe directory as a template.
2. The `Package.swift` depends on `ARCP` via a relative path (`"../.."`).
3. Put your implementation in `Sources/<Name>/main.swift`.
4. Add a `README.md` following the existing pattern (feature table + expected
   output).
