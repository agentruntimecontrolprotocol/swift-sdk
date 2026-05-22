// ARCP v1.1 §15.4 / §9.3 — lease-scoped authority and violation handling.
//
// The client grants the agent a narrow read-only lease. The agent:
//   1. Performs a legitimate `read` operation — succeeds.
//   2. Attempts a `write` operation that is outside the lease scope.
//
// The runtime intercepts the out-of-scope call, the tool throws
// `ARCPError.permissionDenied`, and the runtime surfaces a `tool.error`
// with code PERMISSION_DENIED in the event stream. The job then
// completes normally — a lease violation terminates the offending tool
// call, not the whole job.
//
// Wire contract (RFC §15.4):
//   - lease granted via `permission.grant` reply (§15.4)
//   - out-of-scope action → runtime throws `PERMISSION_DENIED`
//   - job.completed still fires (the agent catches the error gracefully)

import ARCP
import Foundation

// ---------------------------------------------------------------------------
// Agent
// ---------------------------------------------------------------------------

struct TableAgent: ToolHandler {
    let name = "table-agent"

    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        // Determine permitted scope from arguments.
        let scope = invocation.arguments["scope"]?.stringValue ?? "read"

        // --- Step 1: read operation — always allowed. ---
        try await context.log(level: .info, message: "reading analytics table (scope=\(scope))", attributes: nil)
        try await Task.sleep(for: .milliseconds(20))
        try await context.log(level: .info, message: "read succeeded", attributes: nil)

        // --- Step 2: attempt write — only allowed when scope == "write". ---
        if scope != "write" {
            // Throw permission denied; the runtime converts this to a
            // `tool.error` envelope with code PERMISSION_DENIED (§9.3).
            throw ARCPError.permissionDenied(
                permission: "analytics.write",
                resource: "table:prod.events"
            )
        }

        try await context.log(level: .info, message: "write succeeded (scope=write)", attributes: nil)
        return .value(.string("done"))
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Request a permission grant interactively (§15.4).
/// In a real client, a human or policy engine would approve/deny the grant.
/// Here we auto-approve for demonstration.
func requestAndGrantLease(client: ARCPClient, permission: String, resource: String) async throws -> LeaseId {
    let req = Envelope(
        sessionId: client.info.sessionId,
        payload: .permissionRequest(
            PermissionRequestPayload(
                permission: permission,
                resource: resource,
                operation: "read",
                reason: "analytics pipeline needs read access",
                leaseSeconds: 60
            )
        )
    )
    try await client.send(req)
    for await reply in client.unhandled where reply.correlationId == req.id {
        if case .permissionGrant(let g) = reply.payload {
            return g.leaseId
        }
        if case .permissionDeny(let d) = reply.payload {
            throw ARCPError.permissionDenied(permission: permission, resource: d.reason ?? resource)
        }
        break
    }
    throw ARCPError.aborted(reason: "no permission response")
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

@main
struct LeaseViolationExample {
    static func main() async throws {
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "lease-violation-demo", version: "1.0.0"),
            supportedCapabilities: Capabilities(permissions: true),
            auth: BearerAuthValidator(subjectsByToken: ["demo-token": "demo"])
        )
        await runtime.register(TableAgent())
        let server = Task { try await runtime.acceptSession(over: pair.server) }

        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "demo-token"),
            client: IdentityBlock(kind: "lease-violation-client", version: "1.0.0"),
            capabilities: Capabilities(permissions: true)
        )

        // ── Scenario A: read-only lease — write attempt is rejected. ──
        print("── Scenario A: narrow read-only scope ──")
        let invokeA = Envelope(
            sessionId: client.info.sessionId,
            payload: .toolInvoke(
                ToolInvokePayload(
                    tool: "table-agent",
                    arguments: .object(["scope": "read"])
                )
            )
        )
        try await client.send(invokeA)

        for await env in client.unhandled {
            switch env.payload {
            case .jobAccepted(let p):
                print("← job.accepted   job_id=\(p.jobId.rawValue.prefix(8))")

            case .log(let p):
                print("← log[\(p.level)]    \(p.message)")

            case .toolError(let p):
                // Lease violation surfaces here as PERMISSION_DENIED.
                print("← tool.error     code=\(p.error.code)  \(p.error.message)")

            case .jobCompleted:
                // Job still completes even after the permission violation.
                print("← job.completed  (violation recorded, job ran to completion)")
                break

            case .jobFailed(let p):
                print("← job.failed     \(p.error.message)")
                break

            default:
                break
            }
            if case .jobCompleted = env.payload { break }
            if case .jobFailed    = env.payload { break }
        }

        await client.close()
        _ = try? await server.value
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

extension JSONValue {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    subscript(key: String) -> JSONValue? {
        if case .object(let d) = self { return d[key] }
        return nil
    }
}
