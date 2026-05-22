# Lease Expires At

Demonstrates `lease_constraints.expires_at` on `tool.invoke`. The tool
waits until the lease expires, calls `checkLeaseExpiration()`, and the
runtime emits `LEASE_EXPIRED`.

```sh
swift run LeaseExpiresAt
```
