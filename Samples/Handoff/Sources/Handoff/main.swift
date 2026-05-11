// Cheap-tier first; escalate to deep tier via agent.handoff.
//
// The deep runtime is identified by `kind` + pinned `fingerprint`;
// mismatch = refuse. Context rides as an `artifact_id`, not an inline blob.

import ARCP
import CryptoKit
import Foundation

let confidenceThreshold = 0.65
let cheapURL = "wss://haiku-pool.tier1.internal"
let deepURL = "wss://opus-pool.tier3.internal"
let deepKind = "arcp-opus-pool"
let deepFingerprint = "sha256:0a37bf7d61cca21f00..."  // pinned

func packageContext(
    _ client: ARCPClient, transcript: JSONValue
) async throws -> ArtifactRef {
    let body = try Envelope.makeEncoder().encode(transcript)
    let artifactId = ArtifactId("art_\(UUID().uuidString.prefix(14))")
    let put = Envelope(
        sessionId: client.info.sessionId,
        payload: .artifactPut(
            ArtifactPutPayload(
                artifactId: artifactId,
                mediaType: "application/json",
                data: body.base64EncodedString(),
                size: body.count,
                sha256: SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            )
        )
    )
    try await client.send(put)
    for await reply in client.unhandled where reply.correlationId == put.id {
        if case .artifactRef(let r) = reply.payload { return r.ref }
        break
    }
    throw ARCPError.aborted(reason: "no artifact.ref reply")
}

func emitHandoff(
    _ client: ARCPClient, artifactRef: ArtifactRef, traceId: TraceId
) async throws {
    try await client.send(
        Envelope(
            sessionId: client.info.sessionId,
            traceId: traceId,
            payload: .unknown(
                typeName: "agent.handoff",
                payload: .object([
                    "target_runtime": .object([
                        "url": .string(deepURL),
                        "kind": .string(deepKind),
                        "fingerprint": .string(deepFingerprint),
                    ]),
                    "session_id": .string(client.info.sessionId.rawValue),
                    "shared_memory_ref": .object([
                        "artifact_id": .string(artifactRef.artifactId.rawValue),
                        "uri": .string(artifactRef.uri),
                        "sha256": .string(artifactRef.sha256 ?? ""),
                    ]),
                ])
            )
        )
    )
}

@main
struct HandoffExample {
    static func main() async throws {
        let cheap: ARCPClient = await .placeholder  // pinned to "arcp-haiku-pool"
        // Pin runtime kind + fingerprint (RFC §8.3); refuse on mismatch.
        if cheap.info.runtimeIdentity.kind != "arcp-haiku-pool" {
            throw ARCPError.unauthenticated(detail: "cheap kind mismatch")
        }

        let request = "what does CRDT stand for?"
        let traceId = TraceId("trace_\(UUID().uuidString.prefix(12))")

        let (answer, confidence) = await attempt(request: request)
        if confidence >= confidenceThreshold {
            print(answer)
        } else {
            let ref = try await packageContext(
                cheap,
                transcript: .object([
                    "user_request": .string(request),
                    "transcript": .array([
                        .object(["role": .string("user"), "content": .string(request)]),
                        .object(["role": .string("assistant"), "content": .string(answer)]),
                    ]),
                    "cheap_confidence": .number(confidence),
                ])
            )
            try await emitHandoff(cheap, artifactRef: ref, traceId: traceId)
            print("[handed off to \(deepKind) trace_id=\(traceId.rawValue)]")
        }
        await cheap.close()
    }
}
