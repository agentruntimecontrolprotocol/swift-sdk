# CLI

The `arcp` executable (target `arcp-cli`) ships with the SDK and exposes
four subcommands:

```
swift run arcp <subcommand> [options]
```

Or, after `swift build -c release`, run the binary at
`.build/release/arcp` directly.

## `arcp serve`

Accept one ARCP session over `stdin` / `stdout` (NDJSON).

```bash
swift run arcp serve
swift run arcp serve --identity my-agent/1.0
swift run arcp serve --bearer-token secret123
```

Options:

| Flag | Default | Description |
|------|---------|-------------|
| `--identity` | `arcp-cli/1.0` | `name/version` reported in `session.open` |
| `--bearer-token <token>` | — | Accept sessions authenticated with this bearer token |
| `--no-auth` | false | Accept `auth.scheme: none` (insecure; testing only) |
| `--log-level` | `info` | Log level (`debug`, `info`, `warning`, `error`) |

`arcp serve` blocks until `session.close` or `stdin` closes, then exits 0.

## `arcp send`

Submit a single tool invocation to a running `arcp serve` process over stdio.

```bash
swift run arcp send summarise --args '{"text":"hello world"}'
swift run arcp send echo --args '{"msg":"ping"}' --timeout 30
```

Options:

| Flag | Default | Description |
|------|---------|-------------|
| `--args <json>` | `{}` | JSON object of tool arguments |
| `--timeout <seconds>` | 60 | Seconds to wait for `job.completed` |
| `--bearer-token <token>` | — | Bearer token for auth |

Exits 0 on `job.completed`, 1 on `job.failed` or timeout.

## `arcp tail`

Subscribe to all events in an active session and print them as NDJSON.

```bash
swift run arcp tail
swift run arcp tail --filter job_id=01J...
swift run arcp tail --since 2024-01-01T00:00:00Z
```

Options:

| Flag | Default | Description |
|------|---------|-------------|
| `--filter <key>=<val>` | — | Property filter (repeatable) |
| `--since <ISO8601>` | — | Backfill from this timestamp |
| `--session-id <id>` | — | Restrict to one session |

## `arcp replay`

Replay a stored session from an SQLite event log.

```bash
swift run arcp replay events.sqlite sess_01JXXX
```

Reads every envelope stored for `sess_01JXXX` from `events.sqlite` and
prints each as NDJSON in chronological order. Useful for post-mortem
debugging without re-running the agent.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Tool invocation failed (`job.failed`) or bad args |
| 2 | Transport / auth error |
| 64 | Usage error (`EX_USAGE`) |
| 70 | Internal error (`EX_SOFTWARE`) |
