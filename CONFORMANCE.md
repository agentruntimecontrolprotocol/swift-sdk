# Conformance

Implemented versus deferred protocol surfaces are summarized in **README.md**
(Status section). Source modules cite ARCP v1.1 sections in doc comments
(e.g. `// §8`).

Section numbers below refer to **ARCP v1.1** (`spec/docs/draft-arcp-1.1.md`).

## ARCP v1.1 — implemented surfaces

All v1.1 normative surfaces are implemented unless listed under **deferred**
below.

### Core wire protocol (§4 – §6)

- `Envelope` framing (§5), ULID ids, `event_seq` (§8.3), error codes (§12), extension registry
- Four-step handshake (§6.2): `session.open`, `session.challenge` / `session.authenticate` (optional), `session.accepted`, `session.close` (§6.7)
- Auth schemes: `bearer`, `signed_jwt`, `none` (§6.1)
- Capability negotiation (§6.2): structured `capabilities` block, subset checks

### Durable jobs (§7)

- Job state machine: `queued → running → completed | failed | cancelled | timed_out` (§7.3)
- `max_runtime_sec` enforced with a runtime deadline → `TIMEOUT` / `timed_out` (§7.1, §7.3)
- Heartbeats (telemetry only — see below), cooperative cancellation (`job.cancel`, §7.4).
  Interrupts (`interrupt`) are **not advertised by default** — the current
  runtime only transitions the job state to `.blocked` and acks the
  envelope; there is no handler-visible callback that lets the running
  job observe and respond to an interrupt. Leave
  `Capabilities.interrupt = false` unless you have wired your own observer.
- Idempotency (§7.2): identical params replay the cached `job.accepted`;
  conflicting reuse returns `DUPLICATE_KEY`
- `tool.invoke` + `ToolHandler` adapter pattern
- `JobContext`: `checkLeaseExpiration`, `checkCancellation`, `charge`, `log`,
  `metric`, `requestPermission`, `reportProgress`, `openStream`, `emitResultChunk`

### Job events and result streaming (§8)

- Session-scoped, gap-free `event_seq` stamped on job-event envelopes (§8.3)
- Multi-kind streams: `text`, `event`, `log`, `thought`, `metric`, `binary` (base64)
- Back-pressure and cooperative stream close
- `job.result_chunk` wire messages, runtime emission, client `ResultChunkStream` (§8.4)
- `status` event kind (e.g. `phase: "credential_rotated"`) (§8.2)
- Crash-and-resume: same `IdempotencyKey` → same `job_id`, buffered chunk replay

### Permissions and leases (§9, §15.4)

- Permission challenges: `permission.request`, `permission.grant`, `permission.deny`
- Lease lifecycle: grant, refresh, revoke, expiry sweep
- **Renewal stance (§9.5):** a job's `lease_constraints.expires_at` is
  renewal-prohibited — to extend authority a client MUST cancel and resubmit.
  `lease.refresh` / `lease.extended` apply only to §15.4 permission-challenge
  leases (held in `LeaseManager`); no path extends a job's §9.5 `expires_at`.
- `lease_constraints.expires_at` on `tool.invoke`, submission validation
  (UTC `Z` suffix + future, §9.5), in-handler expiry checks via
  `context.checkLeaseExpiration()` evaluated on a monotonic clock (§14)
- Client-side `PermissionHandler` veto

### Cost budget (§9.6)

- `cost.budget` on `ToolInvokePayload`: parse, track, subset checks (§9.4)
- `context.charge(name:amount:currency:)` — per-charge deduction
- `BUDGET_EXHAUSTED` error (`ARCPError.budgetExhausted`, §12)
- Per-charge metrics emitted to client

### Model policy (§9.7)

- `model.use` payload parsing, requested-model matching, runtime policy helper

### Provisioned credentials (§9.8)

- `provisioned_credentials` wire payloads
- Provisioner protocol: issue, rotate, revoke lifecycle
- Rotation emits a `status` event with `phase: "credential_rotated"` (§9.8.2)
- Credential `value`s are delivered to the owning transport only; redacted
  from the event log and subscriber fan-out, never re-transmitted on resume (§14)
- Permanent revocation failures are logged for operators (§9.8.2 / §14)
- In-memory test provisioner, redacted credential descriptions

### Observability (§8.2, §11)

- Structured log events: `log.level`, `log.message`, `log.attributes`
- Metric events: `metric.name`, `metric.value`, `metric.unit`, `metric.dims`
- Trace propagation (§11)
- SQLite event log with replay

### Subscriptions (§7.6)

- `subscription.filter`, backfill, `subscription.backfill_complete` boundary
- **Principal-scoped authorization (§7.6 / §14):** default "same principal
  only"; a filter naming another principal's session is rejected with
  `PERMISSION_DENIED`, and matching is scoped to the subscriber's own
  sessions. Subscribe decisions are audit-logged.
- Resume by `after_message_id` (§6.3) — **same-session only**: the runtime
  replays envelopes for the current session id. Resuming past the retained
  window returns `RESUME_WINDOW_EXPIRED`. Resume-token rotation,
  `checkpoint_id`, and `include_open_streams` are not implemented.

### Artifacts (§8.2 `artifact_ref`)

- Inline-base64 artifacts with configurable retention sweep

### Transports (§4)

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
