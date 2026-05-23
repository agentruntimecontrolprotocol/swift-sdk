# Errors

## `ARCPError`

All ARCP errors are `ARCPError` values — a Swift enum with associated
values that carry context for each error class. Handlers throw
`ARCPError`; the runtime maps them to `error` envelopes on the wire.

Common cases (associated values shown):

```swift
throw ARCPError.invalidArgument(field: "text", detail: "missing")
throw ARCPError.notFound(kind: "artifact", id: id)
throw ARCPError.permissionDenied(permission: "fs.write", resource: path)
throw ARCPError.leaseExpired(leaseId: leaseId, expiredAt: expiry)
throw ARCPError.budgetExhausted(detail: "USD budget exhausted")
throw ARCPError.cancelled(operation: "job", reason: "client cancel")
throw ARCPError.deadlineExceeded(operation: "tool.invoke timeout")
```

## Error codes

Every `ARCPError` maps to a wire `ErrorCode` (RFC §18.2) via
`ARCPError.code`:

| `ARCPError` case | Wire code | Retryable by default |
|------------------|-----------|----------------------|
| `.cancelled(operation:reason:)` | `CANCELLED` | no |
| `.invalidArgument(field:detail:)` | `INVALID_ARGUMENT` | no |
| `.deadlineExceeded(operation:)` | `DEADLINE_EXCEEDED` | **yes** |
| `.notFound(kind:id:)` | `NOT_FOUND` | no |
| `.alreadyExists(kind:id:)` | `ALREADY_EXISTS` | no |
| `.permissionDenied(permission:resource:)` | `PERMISSION_DENIED` | no |
| `.resourceExhausted(reason:retryAfter:)` | `RESOURCE_EXHAUSTED` | **yes** |
| `.failedPrecondition(detail:)` | `FAILED_PRECONDITION` | no |
| `.aborted(reason:)` | `ABORTED` | **yes** |
| `.outOfRange(field:detail:)` | `INVALID_ARGUMENT` | no |
| `.unimplemented(section:detail:)` | `UNIMPLEMENTED` | no |
| `.internal(detail:cause:)` | `INTERNAL` | **yes** |
| `.unavailable(reason:retryAfter:)` | `UNAVAILABLE` | **yes** |
| `.dataLoss(detail:)` | `DATA_LOSS` | no |
| `.unauthenticated(detail:)` | `UNAUTHENTICATED` | no |
| `.heartbeatLost(jobId:missed:)` | `HEARTBEAT_LOST` | no |
| `.leaseExpired(leaseId:expiredAt:)` | `LEASE_EXPIRED` | no |
| `.leaseRevoked(leaseId:reason:)` | `LEASE_REVOKED` | no |
| `.leaseSubsetViolation(detail:)` | `LEASE_SUBSET_VIOLATION` | no |
| `.backpressureOverflow(streamOrSubscription:dropped:)` | `BACKPRESSURE_OVERFLOW` | no |
| `.budgetExhausted(detail:)` | `BUDGET_EXHAUSTED` | no |
| `.agentVersionNotAvailable(agent:version:)` | `AGENT_VERSION_NOT_AVAILABLE` | no |
| `.unknown(message:)` | `UNKNOWN` | no |

`ErrorCode.isRetryableByDefault` follows RFC §18.3.
`ARCPError.isRetryable` provides the same answer with the case-specific
signal applied (e.g. respecting `retryAfter`).

`RATE_LIMITED` is accepted on decode as an alias for
`RESOURCE_EXHAUSTED`; encoding always uses the canonical name.

## Handling errors on the client

```swift
let invocation = try await client.invoke(tool: "process", arguments: args)
switch invocation.outcome {
case .completed(let payload):
    handle(payload)
case .failed(let error):
    if error.code.isRetryableByDefault {
        // schedule retry with backoff
    } else if error.code == .budgetExhausted || error.code == .leaseExpired {
        // not retryable; user/operator must renew before resubmitting
    }
case .cancelled:
    break
}
```

`JobOutcome.failed` carries an `ErrorEnvelope` (the wire shape), not an
`ARCPError`. Use `error.code`, `error.message`, and `error.retryable`
to dispatch. To raise it locally, throw a matching `ARCPError`.

## Error envelopes

An `error` envelope (`ErrorEnvelope`, RFC §18.1) carries:

| Field | Type | Description |
|-------|------|-------------|
| `code` | `ErrorCode` | Canonical error classification |
| `message` | `String` | Human-readable explanation |
| `retryable` | `Bool?` | Caller hint; absent means "consult the default for `code`" |
| `details` | `[String: JSONValue]?` | Structured fields (`field`, `lease_id`, `retry_after_seconds`, ...) |
| `cause` | `ErrorEnvelopeBox?` | Nested cause |
| `traceId` | `TraceId?` | Trace context for the failure |

`ARCPError.toEnvelope(traceId:)` builds the wire form; `ARCPError.code`,
`.message`, `.details`, and `.isRetryable` produce the underlying
fields.

## Unknown extension types

Envelopes with an unrecognised `type` decode as
`.unknown(typeName:payload:)`. `ExtensionRegistry.disposition` then
applies RFC §21.3: registered namespaces are accepted, optional
unknowns are dropped, and everything else triggers a `nack` carrying
`UNIMPLEMENTED`. Ignore unknowns in subscriber loops to stay
forward-compatible.
