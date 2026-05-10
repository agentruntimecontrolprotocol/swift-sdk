import Foundation
import Testing

@testable import ARCP

@Suite("Stdio transport (RFC §22)")
struct StdioTransportTests {
    @Test("Newline-delimited JSON round-trips through Pipe pair")
    func roundTripOverPipes() async throws {
        // Pipe pair: a→b for client→server, b→a for server→client.
        let clientToServer = Pipe()
        let serverToClient = Pipe()
        let clientTransport = StdioTransport(
            inbound: serverToClient.fileHandleForReading,
            outbound: clientToServer.fileHandleForWriting
        )
        let serverTransport = StdioTransport(
            inbound: clientToServer.fileHandleForReading,
            outbound: serverToClient.fileHandleForWriting
        )

        let envelope = Envelope(
            sessionId: SessionId("sess_a"),
            payload: .ack(AckPayload(detail: "hello stdio"))
        )
        try await clientTransport.send(envelope)

        var iter = serverTransport.receive.makeAsyncIterator()
        guard let received = await iter.next() else {
            Issue.record("server received nothing")
            return
        }
        #expect(received.id == envelope.id)
        guard case .ack(let payload) = received.payload else {
            Issue.record("expected ack, got \(received.payload.typeName)")
            return
        }
        #expect(payload.detail == "hello stdio")

        await clientTransport.close()
        await serverTransport.close()
    }

    @Test("Handshake completes over stdio transport")
    func handshakeOverStdio() async throws {
        let clientToServer = Pipe()
        let serverToClient = Pipe()
        let clientTransport = StdioTransport(
            inbound: serverToClient.fileHandleForReading,
            outbound: clientToServer.fileHandleForWriting
        )
        let serverTransport = StdioTransport(
            inbound: clientToServer.fileHandleForReading,
            outbound: serverToClient.fileHandleForWriting
        )
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "openclaw", version: "0.1"),
            supportedCapabilities: Capabilities(streaming: true),
            auth: BearerAuthValidator(subjectsByToken: ["t": "alice"])
        )
        let serverTask = Task { try await runtime.acceptSession(over: serverTransport) }
        let client = try await ARCPClient.open(
            transport: clientTransport,
            auth: AuthBlock(scheme: .bearer, token: "t"),
            client: IdentityBlock(kind: "tester", version: "1"),
            capabilities: Capabilities(streaming: true)
        )
        #expect(client.info.runtimeIdentity.kind == "openclaw")
        await client.close()
        let info = try await serverTask.value
        #expect(info.principal.subject == "alice")
    }
}
