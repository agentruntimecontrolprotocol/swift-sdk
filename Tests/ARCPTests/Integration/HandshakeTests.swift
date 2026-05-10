import Foundation
import Testing

@testable import ARCP

@Suite("Handshake (RFC §8.1)")
struct HandshakeTests {
    @Test("Bearer auth happy path completes without challenge")
    func bearerHappyPath() async throws {
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "example-runtime", version: "0.1"),
            supportedCapabilities: Capabilities(streaming: true, humanInput: true),
            auth: BearerAuthValidator(subjectsByToken: ["secret-token": "alice"])
        )
        let serverTask = Task { try await runtime.acceptSession(over: pair.server) }
        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "secret-token"),
            client: IdentityBlock(kind: "example-client", version: "1.4.2"),
            capabilities: Capabilities(streaming: true, humanInput: true)
        )
        #expect(client.info.runtimeIdentity.kind == "example-runtime")
        #expect(client.info.negotiatedCapabilities.streaming == true)
        #expect(client.info.negotiatedCapabilities.humanInput == true)
        await client.close()
        let serverInfo = try await serverTask.value
        #expect(serverInfo.principal.subject == "alice")
        #expect(serverInfo.clientIdentity.kind == "example-client")
    }

    @Test("Challenge / response handshake completes")
    func challengeResponse() async throws {
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "example-runtime", version: "0.1"),
            supportedCapabilities: Capabilities(),
            auth: BearerAuthValidator(subjectsByToken: ["t": "alice"]),
            challengeRequired: true,
            challengeNonce: { "nonce-fixed" }
        )
        let serverTask = Task { try await runtime.acceptSession(over: pair.server) }
        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "t"),
            client: IdentityBlock(kind: "example-client", version: "1.4.2")
        )
        #expect(client.info.sessionId.rawValue.hasPrefix("sess_"))
        await client.close()
        let serverInfo = try await serverTask.value
        #expect(serverInfo.principal.subject == "alice")
    }

    @Test("Bad token is rejected with UNAUTHENTICATED")
    func badToken() async throws {
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "example-runtime", version: "0.1"),
            supportedCapabilities: Capabilities(),
            auth: BearerAuthValidator(subjectsByToken: ["good": "alice"])
        )
        let serverTask = Task {
            try await runtime.acceptSession(over: pair.server)
        }
        await #expect(throws: ARCPError.self) {
            _ = try await ARCPClient.open(
                transport: pair.client,
                auth: AuthBlock(scheme: .bearer, token: "bad"),
                client: IdentityBlock(kind: "example-client", version: "1.4.2")
            )
        }
        await pair.client.close()
        _ = try? await serverTask.value
    }

    @Test("Anonymous (`scheme=none`) requires negotiated capability")
    func anonymousRequiresCapability() async throws {
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "example-runtime", version: "0.1"),
            supportedCapabilities: Capabilities(),  // anonymous=false
            auth: BearerAuthValidator(subjectsByToken: [:])
        )
        let serverTask = Task { try await runtime.acceptSession(over: pair.server) }
        await #expect(throws: ARCPError.self) {
            _ = try await ARCPClient.open(
                transport: pair.client,
                auth: AuthBlock(scheme: .none),
                client: IdentityBlock(kind: "x", version: "1"),
                capabilities: Capabilities(anonymous: true)
            )
        }
        await pair.client.close()
        _ = try? await serverTask.value
    }

    @Test("Required capability missing rejects handshake with UNIMPLEMENTED")
    func requiredCapabilityMissing() async throws {
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "example-runtime", version: "0.1"),
            supportedCapabilities: Capabilities(),  // streaming=false
            auth: BearerAuthValidator(subjectsByToken: ["t": "alice"]),
            requiredCapabilities: ["streaming"]
        )
        let serverTask = Task { try await runtime.acceptSession(over: pair.server) }
        await #expect(throws: ARCPError.self) {
            _ = try await ARCPClient.open(
                transport: pair.client,
                auth: AuthBlock(scheme: .bearer, token: "t"),
                client: IdentityBlock(kind: "x", version: "1"),
                capabilities: Capabilities(streaming: true)
            )
        }
        await pair.client.close()
        _ = try? await serverTask.value
    }

    @Test("Capability negotiation produces the intersection")
    func capabilityIntersection() async throws {
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "example-runtime", version: "0.1"),
            supportedCapabilities: Capabilities(streaming: true, humanInput: false, artifacts: true),
            auth: BearerAuthValidator(subjectsByToken: ["t": "alice"])
        )
        let serverTask = Task { try await runtime.acceptSession(over: pair.server) }
        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "t"),
            client: IdentityBlock(kind: "example-client", version: "1"),
            capabilities: Capabilities(streaming: true, humanInput: true, artifacts: false)
        )
        #expect(client.info.negotiatedCapabilities.streaming == true)
        #expect(client.info.negotiatedCapabilities.humanInput == false)
        #expect(client.info.negotiatedCapabilities.artifacts == false)
        await client.close()
        _ = try await serverTask.value
    }

    @Test("Ping over an open session round-trips with correlation_id")
    func pingPong() async throws {
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "example-runtime", version: "0.1"),
            supportedCapabilities: Capabilities(),
            auth: BearerAuthValidator(subjectsByToken: ["t": "alice"])
        )
        let serverTask = Task { try await runtime.acceptSession(over: pair.server) }
        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "t"),
            client: IdentityBlock(kind: "x", version: "1")
        )
        let pong = try await client.ping(nonce: "abc")
        #expect(pong.nonce == "abc")
        await client.close()
        _ = try await serverTask.value
    }
}
