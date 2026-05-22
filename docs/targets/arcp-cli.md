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
| `tail` | Subscribe to all events and print them as NDJSON |
| `replay <db> <session>` | Replay a stored session from an SQLite event log |

See [CLI](../cli.md) for full option documentation.

## Source

`Sources/arcp-cli/ArcpCLI.swift` — single file using
[swift-argument-parser](https://github.com/apple/swift-argument-parser).

## Dependencies

| Package | Reason |
|---------|--------|
| `ARCP` | Core library |
| `swift-argument-parser` | `@main`, `ParsableCommand`, flags |
| `swift-log` | Log level flag routing |

## Building for release

```bash
swift build -c release -Xswiftc -warnings-as-errors
```

The release binary is at `.build/release/arcp`.

## Installing globally

```bash
swift build -c release
cp .build/release/arcp /usr/local/bin/arcp
```

Or via [Mint](https://github.com/yonaskolb/Mint):

```bash
mint install agentruntimecontrolprotocol/swift-sdk@1.1.0 --executable arcp
```
