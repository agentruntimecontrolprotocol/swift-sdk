# Errors

## `ARCPError`

All ARCP errors are `ARCPError` values — a Swift enum with associated
values for each error class. Handlers throw `ARCPError`; the runtime
maps them to `error` envelopes on the wire.

Common cases:

```swift
throw ARCPError.invalidArgument(detail: "text field required")
throw ARCPError.notFound(detail: "artifact \(id) not found")
throw ARCPError.permissionDenied(detail: "write not permitted")
throw ARCPError.leaseExpired(leaseId: leaseId, expiredAt: expiry)
throw ARCPError.budgetExhausted(detail: "USD budget exhausted")
throw ARCPError.cancelled
```

## Error codes

Every `ARCPError` maps to a wire `ErrorCode` (RFC §18.2):

| `ARCPError` case | Wire code | Retryable |
|-----------------|-----------|-----------|
| `.invalidArgument` | `INVALID_ARGUMENT` | no |
| `.notFound` | `NOT_FOUND` | no |
| `.alreadyExists` | `ALREADY_EXISTS` | no |
| `.permissionDenied` | `PERMISSION_DENIED` | no |
| `.failedPrecondition` | `FAILED_PRECONDITION` | no |
| `.outOfRange` | `OUT_OF_RANGE` | no |
| `.unimplemented` | `UNIMPLEMENTED` | no |
| `.unauthenticated` | `UNAUTHENTICATED` | no |
| `.leaseExpired` | `LEASE_EXPIRED` | no |
| `.leaseRevoked` | `LEASE_REVOKED` | no |
| `.leaseSubsetViolation` | `LEASE_SUBSET_VIOLATION` | no |
| `.budgetExhausted` | `BUDGET_EXHAUSTED` | no |
| `.agentVersionNotAvailable` | `AGENT_VERSION_NOT_AVAILABLE` | no |
| `.resourceExhausted` | `RESOURCE_EXHAUSTED` | **yes** |
| `.unavailable` | `UNAVAILABLE` | **yes** |
| `.deadlineExceeded` | `DEADLINE_EXCEEDED` | **yes** |
| `.internal` | `INTERNAL` | **yes** |
| `.aborted` | `ABORTED` | **yes** |
| `.cancelled` | `CANCELLED` | — |
| `.unknown` | `UNKNOWN` | no |
| `.heartbeatLost` | `HEARTBEAT_LOST` | — |
| `.dataLoss` | `DATA_LOSS` | no |

`isRetryableByDefault` on `ErrorCode` reflects RFC §18.3.

## Handling errors on the client

```swift
do {
    let (outcome, _) = try await client.invoke(tool: "process", arguments: args)
    switch outcome {
    case .completed(let r): handle(r)
    case .failed(let err):
        if err.code.isRetryableByDefault {
            // schedule retry with backoff
        } else {
            throw err.asARCPError()
        }
    case .cancelled: break
    }
} catch let err as ARCPError {
    switch err {
    case .unauthenticated: // refresh token
    case .leaseExpired:    // re-request lease
    default: throw err
    }
}
```

## Unknown extension types

Envelopes with an unrecognised `type` field decode as
`.unknown(typeName:payload:)`. When a non-optional caller expects a
typed response, the runtime responds with `UNIMPLEMENTED` (RFC §21.3).
Ignore unknowns in subscriber loops to stay forward-compatible.

## Error envelopes

An `error` envelope carries:

| Field | Type | Description |
|-------|------|-------------|
| `code` | `ErrorCode` | Canonical error classification |
| `message` | `String` | Human-readable explanation |
| `detail` | `String?` | Additional machine-readable detail |
| `jobId` | `JobId?` | Affected job, if any |
| `retryAfter` | `TimeInterval?` | Backoff hint for retryable errors |
