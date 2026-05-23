# CLI

The `arcp` executable (target `arcp-cli`) ships with the SDK and exposes
four subcommands:

```
swift run arcp <subcommand> [options]
```

Or, after `swift build -c release`, run the binary at
`.build/release/arcp` directly.

## `arcp serve`

Accept a single ARCP session over `stdin` / `stdout` (NDJSON). Runs an
empty `ARCPRuntime` that advertises `streaming`, `durableJobs`,
`artifacts`, and `subscriptions` and accepts one bearer token; register
your own tool handlers by editing
`Sources/arcp-cli/ArcpCLI.swift`.

```bash
swift run arcp serve
swift run arcp serve --token secret123 --subject orchestrator
```

Options:

| Flag | Default | Description |
|------|---------|-------------|
| `--token <token>` | `demo-token` | Bearer token the runtime will accept |
| `--subject <subject>` | `demo-user` | Subject string mapped to the bearer token |

`arcp serve` writes `arcp serve: ready (wire <version>)` to stderr once
the runtime is up, then blocks until `session.close` or `stdin` closes.

## `arcp send`

Open a session over stdio, submit one `tool.invoke`, and print the
terminal result.

```bash
swift run arcp send summarise --args '{"text":"hello world"}'
swift run arcp send echo --args '{"msg":"ping"}' --token secret123
```

Options:

| Flag | Default | Description |
|------|---------|-------------|
| `--args <json>` | `{}` | JSON value passed as the tool arguments |
| `--token <token>` | `demo-token` | Bearer token for `session.open` |

On `job.completed` the payload is printed as JSON to stdout. On
`job.failed` or `job.cancelled` the error code and message are written
to stderr and the process exits non-zero.

## `arcp tail`

Subscribe over stdio and print every `subscribe.event` payload as one
JSON object per line.

```bash
swift run arcp tail
swift run arcp tail --types log,job.progress,job.completed
```

Options:

| Flag | Default | Description |
|------|---------|-------------|
| `--token <token>` | `demo-token` | Bearer token for `session.open` |
| `--types <csv>` | `log,job.progress,job.completed,job.failed,job.cancelled` | Comma-separated message types passed to `SubscriptionFilter.types` |

The command runs until the transport closes.

## `arcp replay`

Replay envelopes for a session from a SQLite event log file.

```bash
swift run arcp replay events.sqlite sess_01JXXX
swift run arcp replay events.sqlite sess_01JXXX --after msg_01JYY
```

Options:

| Flag | Default | Description |
|------|---------|-------------|
| `--after <message-id>` | — | Skip envelopes at or before this `MessageId` |

Every matching envelope is printed as JSON in chronological order.
Useful for post-mortem debugging without re-running the agent.
