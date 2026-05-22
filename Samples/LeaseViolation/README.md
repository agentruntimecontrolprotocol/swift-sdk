# LeaseViolation

**ARCP v1.1 §15.4 / §9.3 — lease-scoped authority and violation handling**

The client grants the agent a narrow read-only lease. The agent:

1. Performs a legitimate `read` operation — succeeds.
2. Attempts a `write` operation that is outside the lease scope.

The runtime intercepts the out-of-scope call and surfaces a `tool.error` with
code `PERMISSION_DENIED`. The job then completes normally — a lease violation
terminates the offending tool call, **not** the whole job.

## What it shows

| Feature | RFC section |
|---------|-------------|
| `ARCPError.permissionDenied(permission:resource:)` | §9.3 |
| `tool.error` envelope with `PERMISSION_DENIED` code | §9.3 |
| Job continues after a permission violation | §15.4 |
| `permission.request` / `permission.grant` flow | §15.4 |
| `Capabilities(permissions: true)` | §5.1 |

## Running

```bash
swift run
```

## Expected output

```
── Scenario A: narrow read-only scope ──
← job.accepted   job_id=xxxxxxxx
← log[info]      reading analytics table (scope=read)
← log[info]      read succeeded
← tool.error     code=PERMISSION_DENIED  analytics.write denied on table:prod.events
← job.completed  (violation recorded, job ran to completion)
```
