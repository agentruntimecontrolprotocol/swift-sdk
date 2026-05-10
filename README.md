# ARCP — Swift SDK

Swift 6 reference implementation of the **Agent Runtime Control Protocol**
([RFC 0001 v2](RFC-0001-v2.md)).

> **Status:** v0.1 in development. Phase 0 (plan + skeleton) is complete; see
> [`PLAN.md`](PLAN.md) for the phase plan and gate criteria.

## Requirements

- Swift 6.0 toolchain or later (validated against 6.3.1)
- macOS 14+ or Linux (Ubuntu 22.04+ tested)

## Build & test

```bash
swift package plugin --allow-writing-to-package-directory format-source-code
swift package plugin lint-source-code -- --strict
swift build -c release -Xswiftc -warnings-as-errors
swift test --parallel --enable-code-coverage
swift package generate-documentation --target ARCP
```

These five commands constitute the gate command set referenced in
[`PLAN.md`](PLAN.md). Every phase of the implementation must leave them all at
exit code 0.

## What's here today (Phase 0)

- Package layout for `ARCP`, `arcp-cli`, `ARCPTests`, six samples
- Wire-version constant in [`Sources/ARCP/Version.swift`](Sources/ARCP/Version.swift)
- Phase 0 scaffolding tests in [`Tests/ARCPTests/ScaffoldTests.swift`](Tests/ARCPTests/ScaffoldTests.swift)
- Build-tool plugin wiring for `swift-format` and `swift-docc-plugin`

## What's coming (Phase 1+)

- Phase 1: Envelope, ULID-based ids, full error taxonomy, extension registry, SQLite event log
- Phase 2: Every in-scope message payload, four-step handshake, capability negotiation
- Phase 3: Durable jobs with heartbeats, cancellation, interrupts; multi-kind streams with backpressure
- Phase 4: Human-in-the-loop primitives, permission/lease lifecycle
- Phase 5: Subscriptions with backfill, inline-base64 artifacts, resume
- Phase 6: WebSocket and stdio transports
- Phase 7: CLI, runnable samples, full conformance review, `v0.1.0` tag

## RFC mapping

The plan in [`PLAN.md`](PLAN.md) §5 maps every in-scope wire message type to
its `MessageType` enum case and payload struct. Out-of-scope types are
enumerated in §2 and decoded as `.unknown`, rejected per RFC §21.3 with
`UNIMPLEMENTED`.

## License

TBD (matches the parent repository).
