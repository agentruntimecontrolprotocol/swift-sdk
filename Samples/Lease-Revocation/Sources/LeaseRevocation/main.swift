// Warehouse DB admin agent. Reads pre-granted; writes prompt operator.
//
// Granted leases are cached per (table, op). Mid-statement `lease.revoked`
// drops the cache entry so the next statement re-prompts.

import ARCP
import Foundation

let preGranted = ["public.orders", "public.customers", "warehouse.fct_revenue_daily"]
let readLeaseSeconds = 60 * 60
let writeLeaseSeconds = 5 * 60

actor LeaseCache {
    struct Entry: Sendable {
        let leaseId: LeaseId
        let expires: Date
    }
    private var entries: [String: Entry] = [:]  // key: "table:op"

    func get(table: String, op: String) -> Entry? {
        guard let e = entries["\(table):\(op)"], e.expires > Date() else { return nil }
        return e
    }
    func put(table: String, op: String, entry: Entry) { entries["\(table):\(op)"] = entry }
    func revoke(leaseId: LeaseId) {
        for (k, v) in entries where v.leaseId == leaseId { entries.removeValue(forKey: k) }
    }
}

func requestLease(
    _ client: ARCPClient,
    permission: String, table: String, operation: String,
    seconds: Int, reason: String
) async throws -> LeaseCache.Entry {
    let req = Envelope(
        sessionId: client.info.sessionId,
        payload: .permissionRequest(
            PermissionRequestPayload(
                permission: permission,
                resource: "table:\(table)",
                operation: operation,
                reason: reason,
                requestedLeaseSeconds: seconds
            )
        )
    )
    try await client.send(req)
    for await reply in client.unhandled where reply.correlationId == req.id {
        switch reply.payload {
        case .leaseGranted(let g): return .init(leaseId: g.leaseId, expires: g.expiresAt)
        case .permissionDeny(let d):
            throw ARCPError.permissionDenied(permission: permission, resource: d.resource)
        default: continue
        }
    }
    throw ARCPError.aborted(reason: "no lease reply")
}

struct StatementClass: Sendable {
    let op: String
    let tables: [String]
}

func authorize(
    _ client: ARCPClient, sql: String, cache: LeaseCache
) async throws -> String {
    let cls = classify(sql: sql)
    let seconds = cls.op == "read" ? readLeaseSeconds : writeLeaseSeconds
    for table in cls.tables {
        if await cache.get(table: table, op: cls.op) != nil { continue }
        let entry = try await requestLease(
            client,
            permission: "db.\(cls.op)", table: table, operation: cls.op,
            seconds: seconds, reason: "\(cls.op.uppercased()) on \(table): \(sql.prefix(80))"
        )
        await cache.put(table: table, op: cls.op, entry: entry)
    }
    return cls.op
}

func handleInbound(_ env: Envelope, cache: LeaseCache) async {
    if case .leaseRevoked(let payload) = env.payload {
        await cache.revoke(leaseId: payload.leaseId)
    }
}

@main
struct LeaseRevocationExample {
    static func main() async throws {
        let client: ARCPClient = await .placeholder
        let cache = LeaseCache()

        let drain = Task {
            for await env in client.unhandled {
                await handleInbound(env, cache: cache)
            }
        }

        // Pre-grant the broad reads at session open. SELECT against these
        // tables is then free until revocation.
        for table in preGranted {
            let entry = try await requestLease(
                client,
                permission: "db.read", table: table, operation: "read",
                seconds: readLeaseSeconds, reason: "bootstrap"
            )
            await cache.put(table: table, op: "read", entry: entry)
        }

        _ = try await authorize(
            client,
            sql: "SELECT count(*) FROM public.orders WHERE shipped_at::date = current_date - 1",
            cache: cache)
        _ = try await authorize(
            client,
            sql: "UPDATE public.orders SET status='refunded' WHERE id=4812",
            cache: cache)

        drain.cancel()
        await client.close()
    }
}
