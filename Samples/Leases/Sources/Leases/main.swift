// Sandboxed on-call agent. Lease-gated shell, reasoning streamed.
//
// Read leases are coarse and long-lived; write leases are scoped to
// (binary, target) and last only as long as the action.

import ARCP
import Foundation

let readBinaries: Set<String> = [
    "/usr/bin/journalctl", "/usr/bin/cat", "/usr/bin/ss", "/usr/bin/ps",
]
let writeBinaries: Set<String> = ["/usr/bin/systemctl", "/usr/bin/kill"]
let readLeaseSeconds = 30 * 60
let writeLeaseSeconds = 60

struct ClassifiedCommand: Sendable {
    let permission: String
    let resource: String
    let operation: String
    let leaseSeconds: Int
}

func classify(argv: [String], host: String) throws -> ClassifiedCommand {
    let binary = argv[0]
    if readBinaries.contains(binary) {
        return .init(
            permission: "host.read", resource: "host:\(host)", operation: "read",
            leaseSeconds: readLeaseSeconds)
    }
    if writeBinaries.contains(binary) {
        let target = binary == "/usr/bin/systemctl" ? argv[2] : argv[1]
        return .init(
            permission: "host.write",
            resource: "host:\(host)/\(binary)/\(target)",
            operation: "write",
            leaseSeconds: writeLeaseSeconds
        )
    }
    throw ARCPError.permissionDenied(permission: "shell", resource: "binary not allowed: \(binary)")
}

func acquireLease(
    _ client: ARCPClient,
    permission: String,
    resource: String,
    operation: String,
    seconds: Int,
    reason: String
) async throws -> LeaseId {
    let request = Envelope(
        sessionId: client.info.sessionId,
        payload: .permissionRequest(
            PermissionRequestPayload(
                permission: permission,
                resource: resource,
                operation: operation,
                reason: reason,
                requestedLeaseSeconds: seconds
            )
        )
    )
    try await client.send(request)
    for await reply in client.unhandled where reply.correlationId == request.id {
        switch reply.payload {
        case .leaseGranted(let g): return g.leaseId
        case .permissionDeny(let d):
            throw ARCPError.permissionDenied(permission: "shell", resource: d.reason)
        default: continue
        }
    }
    throw ARCPError.aborted(reason: "no permission reply")
}

func runCommand(
    _ client: ARCPClient, argv: [String], reason: String, host: String
) async throws -> String {
    let cls = try classify(argv: argv, host: host)
    let lease = try await acquireLease(
        client,
        permission: cls.permission,
        resource: cls.resource,
        operation: cls.operation,
        seconds: cls.leaseSeconds,
        reason: reason
    )
    // The lease is the only guard. Spawn the subprocess elsewhere.
    return "<would run \(argv) under lease \(lease.rawValue)>"
}

func emitThought(
    _ client: ARCPClient, streamId: StreamId, sequence: Int, text: String
) async throws {
    try await client.send(
        Envelope(
            sessionId: client.info.sessionId,
            streamId: streamId,
            payload: .streamChunk(
                StreamChunkPayload(sequence: sequence, content: text, role: "assistant_thought")
            )
        )
    )
}

@main
struct LeasesExample {
    static func main() async throws {
        let client: ARCPClient = await .placeholder  // identity advertises trust=constrained
        let streamId = StreamId("str_\(Int(Date().timeIntervalSince1970))")
        try await client.send(
            Envelope(
                sessionId: client.info.sessionId,
                streamId: streamId,
                payload: .streamOpen(StreamOpenPayload(kind: .thought))
            )
        )

        var seq = 0
        for try await step in llmLoop(prompt: "api-gateway pod is OOMing every 4 minutes") {
            try await emitThought(client, streamId: streamId, sequence: seq, text: step.thought)
            seq += 1
            if let call = step.toolCall {
                do {
                    _ = try await runCommand(
                        client, argv: call.argv, reason: call.reason, host: "edge-pod-04")
                } catch {
                    continue  // PERMISSION_DENIED feeds back into the next prompt.
                }
            }
            if let final = step.final {
                print(final)
                break
            }
        }
        await client.close()
    }
}
