# Recipe: Email Vendor Leases

**ARCP v1.1 §15.4 / §6.4 — lease-gated tool permissions**

An email triage agent reads a vendor inbox, drafts a reply, then requests
`send_reply` permission via `context.requestPermission`. The client registers
a `ReadOnlyVendorPermissionHandler` that enforces a narrow read-only scope and
denies the request. The agent catches `ARCPError.permissionDenied`, returns the
drafted reply unsent, and the job completes normally.

## What it shows

| Feature | RFC section |
|---------|-------------|
| `context.requestPermission(permission:resource:operation:reason:leaseSeconds:)` | §15.4 |
| `PermissionHandler` — client-side veto of agent permission requests | §6.4 |
| `ARCPError.permissionDenied(permission:resource:)` catch in agent | §9.3 |
| Job completes normally after a permission denial | §15.4 |

## Run

```bash
cd Recipes/email-vendor-leases && swift run
```

## Expected output

```
── vendor inbox triage: send_reply permission denied by narrow lease ──
→ email.triage submitted
← job.accepted  job_id=xxxxxxxx
← log[info]  step 1: listing vendor inbox
← log[info]  step 2: reading vendor message msg-001
← log[info]  step 3: requesting permission for send_reply
← log[warning]  send_reply denied — drafted reply not sent
← job.completed  sent=false
   drafted_reply=Thank you for the reminder. Payment for invoice #1042 is scheduled.
   denial_reason=tool.call denied on send_reply
```

## Key files

| File | What it shows |
|------|---------------|
| `Sources/EmailVendorLeases/main.swift` | End-to-end wiring |
| `TriageAgent` | `requestPermission` + `permissionDenied` catch |
| `ReadOnlyVendorPermissionHandler` | `PermissionHandler` enforcement |

## Related samples

- [LeaseViolation](../../Samples/LeaseViolation) — runtime-level `PERMISSION_DENIED` on out-of-scope tool call
- [Leases](../../Samples/Leases) — lease-gated shell agent with read/write scope
- [Permission-Challenge](../../Samples/Permission-Challenge) — two-party human-in-the-loop veto
