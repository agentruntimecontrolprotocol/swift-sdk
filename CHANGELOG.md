# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2026-05-25

### Fixed

- **Security.** `JWTAuthValidator` now requires a matching `nonce` claim when
  the runtime issues a challenge.
- **Security.** `ModelUse.subsetViolation(of:)` uses a real glob-inclusion check
  so wildcard parents with suffix segments can no longer be escaped.
- Lease durations validated at grant/refresh; `handleLeaseRefresh` surfaces
  errors instead of swallowing them.
- `PendingRegistry` and `ARCPClient.ping` use a slot state machine so the
  waiter is registered before any timeout race.
- Pending invocations are failed and progress/result streams are finished when
  the transport closes; invoke's send-error path cleans up state.
- `ARCPRuntime.register` race window closed by inserting the `jobManagers`
  entry before iterating `registeredHandlers`.
- Subscriptions track owner session id; cleanup runs when the session ends.
  `subscribe.event` envelopes are skipped during `route()`, preventing
  recursive cascade on empty filters.
- `StreamManager.subscribeInbound` refuses a second subscriber for the same
  stream id with `failedPrecondition`.
- Client dispatch: unmatched `job.progress`, `job.result_chunk`, and
  `tool.error` envelopes fall through to `unhandled` instead of being silently
  dropped or double-delivered.
- Idempotency keys persist the terminal `job.completed/failed/cancelled`
  payload (scoped by principal + key) and replay it on duplicate invokes
  without re-running the handler.
- Trace fields default to `Tracing.current`; `JobManager` propagates the
  inbound trace context across job lifecycle and handler emissions.
- Artifact retention sweep starts in `ARCPRuntime.init`; lease expiry sweep
  starts in `JobManager.init`.
- `CredentialManager.rotate` keeps every credential returned by the
  provisioner instead of silently discarding extras.
- ULID generator preserves strict monotonicity across equal/backward clocks
  and overflow.
- O(1) mailbox drain via head index with periodic compaction.
- `jwt-kit` pinned under 5.3.0 to keep the package buildable on Swift 6.1.

### Changed

- `Resume` guide and `CONFORMANCE.md` narrowed to same-session replay only.
- Interrupt support documented as wire-acked only — no handler observation
  callback.
- Heartbeat recovery documented as telemetry-only.

### Added

- DocC comments across the most user-facing public surface.
- `.spi.yml` for Swift Package Index DocC hosting.
- Unit / integration coverage for `Mailbox`, `LeaseManager`,
  `PendingRegistry`, `JWTAuth`, client dispatch fallback, subscription
  cleanup, idempotency replay, and ULID burst.

## [1.1.0] - 2026-05-22

### Added

- Full ARCP v1.1 wire surface: `job.result_chunk` (text / event / log /
  thought / metric / binary), crash-and-resume via `IdempotencyKey`,
  `lease_constraints.expires_at`, `cost.budget`, `model.use`, and
  `provisioned_credentials` lifecycle.
- Transports: `StdioTransport` (NDJSON over stdio) and `WebSocketTransport`
  (client-side).
- `docs/` tree: architecture overview, RFC mapping, lifecycle state diagrams,
  troubleshooting, and §21 extension authoring guide.
- `Recipes/` runnable examples: `email-vendor-leases`, `mcp-skill`,
  `multi-agent-budget`, `stream-resume`.

## [0.1.0] - 2026-05-10

### Added

- Initial reference SDK release aligned with ARCP protocol v1.1 (see README status).

