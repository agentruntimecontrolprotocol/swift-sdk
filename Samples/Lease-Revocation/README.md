# Lease-Revocation

Warehouse DB admin agent. Reads against pre-granted tables run free.
INSERT / UPDATE / DELETE / DDL trigger a synchronous `permission.request`
scoped to the specific table and operation.

## Before ARCP

Two failure modes: (1) the agent has a write-capable DB role and
operators audit Slack, hoping; (2) writes go through a separate
"approval" service that the agent doesn't actually understand — when
approval is denied, the agent gets a 403 with no structure and either
gives up or retries blindly.

## With ARCP

```swift
let cls = classify(sql: sql)                      // sqlglot: read / write / ddl
for table in cls.tables {
    if await cache.get(table: table, op: cls.op) != nil { continue }
    let entry = try await requestLease(
        client,
        permission: "db.\(cls.op)", table: table, operation: cls.op,
        seconds: cls.op == "read" ? readLeaseSeconds : writeLeaseSeconds,
        reason: "..."
    )
    await cache.put(table: table, op: cls.op, entry: entry)
}
```

Granted leases are cached. A mid-statement `lease.revoked` envelope drops
the cache entry so the next call re-prompts.

## ARCP primitives

- Permission challenge — RFC §15.4.
- Full lease lifecycle (request, grant, use, refresh, revoke) — §15.5.
- `PERMISSION_DENIED` / `LEASE_EXPIRED` / `LEASE_REVOKED` — §18.2.

## File tour

- `Sources/LeaseRevocation/main.swift` — bootstraps reads, runs two
  queries, drains revocations into the cache.
- `Sources/LeaseRevocation/SQL.swift` — `classify(sql:)` stub +
  `ARCPClient.placeholder`.

## Variations

- Replace operator approval with a policy engine (Cedar, OPA).
- Promote read leases to row-level by encoding a row-filter SQL into
  `resource` (`table:public.orders/region=us`).
- Stream every DDL into Subscriptions for change history.
