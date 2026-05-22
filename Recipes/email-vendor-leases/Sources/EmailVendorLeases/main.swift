/// Recipe: Email Vendor Leases
///
/// Demonstrates lease-gated tool permissions for a vendor email triage agent.
/// The agent requests `send_reply` permission, which the client denies via a
/// narrow read-only `PermissionHandler`. The agent catches the denial, returns
/// a drafted (unsent) reply, and the job completes normally.
///
/// Spec: §15.4 (leases / permission.request), §6.4 (permission.grant / deny)
///
/// Run:
///   cd Recipes/email-vendor-leases && swift run

import ARCP
import Foundation

// MARK: - Agent

/// Reads a vendor inbox message, drafts a reply, then requests `send_reply`
/// permission. If denied by the client's PermissionHandler, it returns the
/// draft without sending.
struct TriageAgent: ToolHandler {
    let name = "email.triage"

    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        try await context.log(level: .info, message: "step 1: listing vendor inbox", attributes: nil)

        let messageId = "msg-001"
        let vendor    = "acme@vendor.example"

        try await context.log(
            level: .info,
            message: "step 2: reading vendor message \(messageId)",
            attributes: ["vendor.event": .string("email.read"), "from": .string(vendor)]
        )

        let draftedReply = "Thank you for the reminder. Payment for invoice #1042 is scheduled."

        try await context.log(level: .info, message: "step 3: requesting permission for send_reply", attributes: nil)

        do {
            _ = try await context.requestPermission(
                permission: "tool.call",
                resource:   "send_reply",
                operation:  "write",
                reason:     "Agent wants to send reply to vendor invoice email \(messageId)",
                leaseSeconds: 60
            )
            try await context.log(level: .info, message: "send_reply permitted — reply sent", attributes: nil)
            return .value(.object([
                "message_id":    .string(messageId),
                "drafted_reply": .string(draftedReply),
                "sent":          .bool(true),
            ]))
        } catch ARCPError.permissionDenied(let permission, let resource) {
            try await context.log(
                level: .warning,
                message: "send_reply denied — drafted reply not sent",
                attributes: [
                    "denied_permission": .string(permission),
                    "denied_resource":   .string(resource),
                ]
            )
            return .value(.object([
                "message_id":    .string(messageId),
                "drafted_reply": .string(draftedReply),
                "sent":          .bool(false),
                "denial_reason": .string("\(permission) denied on \(resource)"),
            ]))
        }
    }
}

// MARK: - Permission handler

/// Enforces a read-only vendor scope: denies any `send_reply` request.
struct ReadOnlyVendorPermissionHandler: PermissionHandler {
    func handle(_ request: PermissionRequestPayload, jobId: JobId?) async throws -> Decision {
        if request.resource == "send_reply" {
            return .denied(reason: "send_reply is outside the approved read-only lease scope")
        }
        return .granted(seconds: 60)
    }
}

// MARK: - Main

@main struct EmailVendorLeases {
    static func main() async throws {
        let pair = MemoryTransport.makePair()

        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "email-vendor-leases-runtime", version: "1.0.0"),
            supportedCapabilities: Capabilities(),
            auth: BearerAuthValidator(subjectsByToken: ["demo-token": "service"])
        )
        await runtime.register(TriageAgent())
        let server = Task { try await runtime.acceptSession(over: pair.server) }

        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "demo-token"),
            client: IdentityBlock(kind: "email-vendor-leases-client", version: "1.0.0"),
            capabilities: Capabilities()
        )
        client.setPermissionHandler(ReadOnlyVendorPermissionHandler())

        print("── vendor inbox triage: send_reply permission denied by narrow lease ──")

        let env = Envelope(
            sessionId: client.info.sessionId,
            payload: .toolInvoke(ToolInvokePayload(
                tool:      "email.triage",
                arguments: .object(["inbox": .string("vendor")])
            ))
        )
        try await client.send(env)
        print("→ email.triage submitted")

        for await reply in client.unhandled {
            switch reply.payload {
            case .jobAccepted(let p):
                print("← job.accepted  job_id=\(p.jobId.rawValue.prefix(8))")

            case .log(let p):
                print("← log[\(p.level)]  \(p.message)")

            case .jobCompleted(let p):
                if let r = p.result, case .object(let obj) = r {
                    let sent = (obj["sent"] == .bool(true))
                    print("← job.completed  sent=\(sent)")
                    if case .string(let s) = obj["drafted_reply"] {
                        print("   drafted_reply=\(s)")
                    }
                    if !sent, case .string(let s) = obj["denial_reason"] {
                        print("   denial_reason=\(s)")
                    }
                }
                await client.close()
                _ = try? await server.value
                return

            case .jobFailed(let p):
                print("← job.failed  \(p.error.message)")
                await client.close()
                _ = try? await server.value
                return

            default:
                break
            }
        }
    }
}
