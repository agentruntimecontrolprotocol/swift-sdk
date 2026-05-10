import ARCP
import Foundation

/// Sample 01 — open a session over an in-memory transport pair, ping the
/// runtime, and close. Demonstrates the smallest end-to-end ARCP exchange.
@main
struct Sample01MinimalSession {
    static func main() async throws {
        print("Sample 01 — minimal session (wire \(ARCPVersion.wire))")
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "sample-runtime", version: ARCPVersion.sdk),
            supportedCapabilities: Capabilities(),
            auth: BearerAuthValidator(subjectsByToken: ["demo": "alice"])
        )
        let serverTask = Task { try await runtime.acceptSession(over: pair.server) }

        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "demo"),
            client: IdentityBlock(kind: "sample-client", version: ARCPVersion.sdk)
        )
        print("session opened: \(client.info.sessionId)")

        let pong = try await client.ping(nonce: "hello")
        print("pong nonce: \(pong.nonce ?? "<none>")")

        await client.close()
        _ = try await serverTask.value
        print("session closed")
    }
}
