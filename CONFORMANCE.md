# Conformance

Implemented versus deferred protocol surfaces are summarized in **README.md**
(Status section). Source modules cite RFC sections in doc comments
(e.g. `// RFC §8`).

## ARCP v1.1 — implemented surfaces

All v1.1 normative surfaces are implemented unless listed under **deferred**
below.

### Core wire protocol (§4 – §8)

- `Envelope` framing, ULID ids, error codes, extension registry
- Four-step handshake (§8.1): `session.open`, `session.accept`, `session.ready`, `session.close`
- Auth schemes: `bearer` (§8.2), `signed_jwt` (§8.3), `none` (§8.4)
- Capability negotiation (§7): structured `capabilities` block, subset checks

### Durable jobs (§9 – §14)

- Job state machine: `queued → running → completed | failed | cancelled`
- Heartbeats, cooperative cancellation (`job.cancel`), interrupts (`job.interrupt`)
- `tool.invoke` + `ToolHandler` adapter pattern
- `JobContext`: `checkLeaseExpiration`, `checkCancellation`, `charge`, `log`,
  `metric`, `requestPermission`, `reportProgress`, `openStream`, `emitResultChunk`

### Streaming (§19)

- Multi-kind streams: `text`, `event`, `log`, `thought`, `metric`, `binary` (base64)
- Back-pressure and cooperative stream close
- `job.result_chunk` wire messages, runtime emission, client `ResultChunkStream`
- Crash-and-resume: same `IdempotencyKey` → same `job_id`, buffered chunk replay

### Permissions and leases (§6.4, §15)

- Permission challenges: `permission.request`, `permission.grant`, `permission.deny`
- Lease lifecycle: grant, refresh, revoke, expiry sweep
- `lease_constraints.expires_at` on `tool.invoke`, submission validation,
  in-handler expiry checks via `context.checkLeaseExpiration()`
- Client-side `PermissionHandler` veto

### Cost budget (§17.3, §18.3)

- `cost.budget` on `ToolInvokePayload`: parse, track, subset checks
- `context.charge(name:amount:currency:)` — per-charge deduction
- `BUDGET_EXHAUSTED` error (`ARCPError.budgetExhausted`)
- Per-charge metrics emitted to client

### Model policy (§16)

- `model.use` payload parsing, requested-model matching, runtime policy helper

### Provisioned credentials (§20)

- `provisioned_credentials` wire payloads
- Provisioner protocol: issue, rotate, revoke lifecycle
- In-memory test provisioner, redacted credential descriptions

### Observability (§17)

- Structured log events: `log.level`, `log.message`, `log.attributes`
- Metric events: `metric.name`, `metric.value`, `metric.unit`, `metric.dims`
- SQLite event log with replay

### Subscriptions (§18)

- `subscription.filter`, backfill, `subscription.backfill_complete` boundary
- Resume by `after_message_id`

### Artifacts (§21)

- Inline-base64 artifacts with configurable retention sweep

### Transports (§5)

- `MemoryTransport` — synchronous in-process (used by all tests and samples)
- `StdioTransport` — NDJSON framing over stdin/stdout
- `WebSocketTransport` — client-side; server-side partial (see **deferred**)

---

## Deferred to v1.2

| Surface | Reason |
|---------|--------|
| mTLS (`mtls`) auth scheme | Requires SecureTransport / BoringSSL integration |
| OAuth 2.0 (`oauth2`) auth scheme | Requires token endpoint + PKCE flow |
| Sidecar binary stream frames | Spec section still under revision |
| Scheduled jobs | Runtime scheduler not yet implemented |
| Multi-agent delegation / handoff | Depends on trust-elevation surface |
| Trust elevation | Policy engine not yet implemented |
| Checkpoint-based resume | Requires durable checkpoint store |
| Full WebSocket server | `WebSocketKit.WebSocket` server-side init is `internal` |

For cross-language conformance tracking, use the monorepo `spec/` tree and
shared issue milestones.
