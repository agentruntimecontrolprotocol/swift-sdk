# Target: `arcp-cli`

The `arcp-cli` executable target provides the `arcp` command-line tool.

```bash
swift run arcp <subcommand> [options]
# or after swift build -c release:
.build/release/arcp <subcommand> [options]
```

## Subcommands

| Subcommand | Description |
|------------|-------------|
| `serve` | Accept one ARCP session over stdio (NDJSON) |
| `send <tool>` | Submit a single tool invocation and print the result |
| `tail` | Subscribe over stdio and print every `subscribe.event` payload |
| `replay <db> <session>` | Replay envelopes for a session from a SQLite event log |

See [CLI](../cli.md) for full option documentation.

## Source

`Sources/arcp-cli/ArcpCLI.swift` — single file using
[swift-argument-parser](https://github.com/apple/swift-argument-parser).

## Dependencies

| Package | Reason |
|---------|--------|
| `ARCP` | Core library |
| `swift-argument-parser` | `@main`, `AsyncParsableCommand`, flags |
| `swift-log` | Logger labels for CLI output |

## Building for release

```bash
swift build -c release
```

The release binary is at `.build/release/arcp`.

## Installing globally

```bash
swift build -c release
cp .build/release/arcp /usr/local/bin/arcp
```

Or with [Mint](https://github.com/yonaskolb/Mint):

```bash
mint install agentruntimecontrolprotocol/swift-sdk --executable arcp
```
