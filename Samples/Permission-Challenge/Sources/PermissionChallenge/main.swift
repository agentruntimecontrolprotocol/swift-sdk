// Generator proposes; reviewer holds veto via permission.request.
//
// Two ARCP sessions, one per agent. The reviewer's "no" arrives at the
// generator as a structured PERMISSION_DENIED — not a 403 with a stack.

import ARCP
import CryptoKit
import Foundation

let maxRevisions = 4

struct Patch: Sendable { let diff: String }

struct ReviewVerdict: Sendable {
    let grant: Bool
    let reason: String
}

func fingerprint(_ diff: String) -> String {
    let digest = SHA256.hash(data: Data(diff.utf8))
    return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
}

func requestApply(
    _ client: ARCPClient, ticketId: String, patch: Patch
) async throws -> LeaseId {
    let fp = fingerprint(patch.diff)
    let req = Envelope(
        sessionId: client.info.sessionId,
        // Same key per (ticket, diff): identical patch dedupes at runtime.
        idempotencyKey: IdempotencyKey("review:\(ticketId):\(fp)"),
        payload: .permissionRequest(
            PermissionRequestPayload(
                permission: "repo.write",
                resource: "ticket:\(ticketId)/\(fp)",
                operation: "apply_patch",
                reason: "apply patch",
                requestedLeaseSeconds: 90
            )
        )
    )
    try await client.send(req)
    for await reply in client.unhandled where reply.correlationId == req.id {
        switch reply.payload {
        case .leaseGranted(let g): return g.leaseId
        case .permissionDeny(let d):
            throw ARCPError.permissionDenied(permission: "repo.write", resource: d.resource)
        default: continue
        }
    }
    throw ARCPError.aborted(reason: "no reply")
}

func respond(
    _ reviewer: ARCPClient, request: Envelope, verdict: ReviewVerdict
) async throws {
    guard case .permissionRequest(let p) = request.payload else { return }
    let payload: MessageType =
        verdict.grant
        ? .permissionGrant(
            PermissionGrantPayload(
                permission: p.permission, resource: p.resource,
                operation: p.operation, leaseSeconds: 90
            ))
        : .permissionDeny(
            PermissionDenyPayload(
                permission: p.permission, resource: p.resource, reason: verdict.reason
            ))
    try await reviewer.send(
        Envelope(
            sessionId: reviewer.info.sessionId,
            correlationId: request.id,
            payload: payload
        )
    )
}

func reviewerLoop(_ reviewer: ARCPClient, ticket: String) async throws {
    for await env in reviewer.unhandled {
        if case .permissionRequest = env.payload {
            let verdict = await review(ticket: ticket, request: env)
            try await respond(reviewer, request: env, verdict: verdict)
        }
    }
}

@main
struct PermissionChallengeExample {
    static func main() async throws {
        let generator: ARCPClient = await .placeholder
        let reviewer: ARCPClient = await .placeholder

        let ticketId = "JIRA-4812"
        let ticket =
            "Reject JWTs whose `aud` does not match the configured audience. Add a unit test."

        let revTask = Task { try await reviewerLoop(reviewer, ticket: ticket) }
        defer { revTask.cancel() }

        var priorDenial: String? = nil
        for _ in 0..<maxRevisions {
            let patch = await propose(ticket: ticket, priorDenial: priorDenial)
            do {
                let lease = try await requestApply(generator, ticketId: ticketId, patch: patch)
                print("applied \(fingerprint(patch.diff)) lease=\(lease.rawValue)")
                await generator.close()
                await reviewer.close()
                return
            } catch let e as ARCPError {
                if case .permissionDenied = e {
                    priorDenial = String(describing: e)
                    continue
                }
                throw e
            }
        }
        print("abandoned after maxRevisions")
        await generator.close()
        await reviewer.close()
    }
}
