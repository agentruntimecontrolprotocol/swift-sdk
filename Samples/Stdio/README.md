# Stdio

**ARCP v1.1 §4.2 / §22 — NDJSON transport over `FileHandle` pairs**

`StdioTransport` streams newline-delimited JSON over arbitrary `FileHandle`
instances. In production the default `init()` uses the process's own
`stdin`/`stdout`; this sample wires two `Foundation.Pipe` objects together
so the server and client run in the same process — no external piping needed.

## What it shows

| Feature | RFC section |
|---------|-------------|
| `StdioTransport(inbound:outbound:)` | §22 |
| `Foundation.Pipe` cross-connect for in-process testing | §22 |
| NDJSON wire format (one JSON object per line) | §4.2 |
| Identical API surface to any other transport | §4 |

## Common deployment patterns

| Pattern | Setup |
|---------|-------|
| Shell pipe | `echo '...' \| ./server \| ./client` |
| Child process | Parent spawns server, connects its `Pipe` FDs |
| Container pair | Two sidecars share a Unix-socket pair |
| In-process test (this sample) | Two `Pipe` objects cross-connected |

## Running

```bash
swift run
```

## Expected output

```
connecting over NDJSON pipe transport...
session open  session_id=xxxxxxxx
→ tool.invoke sent (one NDJSON line on the pipe)
← job.accepted  job_id=yyyyyyyy
← log[info]  echo handler running
← job.completed  result=echo: hello over stdio
```
