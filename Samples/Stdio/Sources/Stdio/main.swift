// ARCP v1.1 §4.2 / §22 — NDJSON transport over FileHandle pairs.
//
// `StdioTransport` streams newline-delimited JSON over arbitrary
// `FileHandle` instances. In a deployed process the transport uses the
// process's own stdin / stdout — the default init requires no arguments:
//
//   let transport = StdioTransport()   // .standardInput / .standardOutput
//
// Common deployment patterns:
//   • Shell pipe:      echo '...' | ./server | ./client
//   • Child process:   parent spawns server, connects its Pipe FDs
//   • Container pair:  two sidecars share a Unix-socket pair
//
// This sample wires two `Pipe` objects together so the server and client
// run in the same process — no external piping required. The wire format
// is identical to the production case: one JSON object per line.

import ARCP
import Foundation

// ---------------------------------------------------------------------------
// A simple echo tool
// ---------------------------------------------------------------------------

struct EchoTool: ToolHandler {
    let name = "echo"

    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        let msg = invocation.arguments["message"]?.stringValue ?? "(empty)"
        try await context.log(level: .info, message: "echo handler running", attributes: nil)
        return .value(.string("echo: \(msg)"))
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

@main
struct StdioExample {
    static func main() async throws {
        // Cross-connect two `Pipe` objects so bytes flow bidirectionally.
        //
        //   clientToServer.fileHandleForWriting → serverTransport.inbound
        //   serverToClient.fileHandleForWriting → clientTransport.inbound
        //
        let serverToClient = Pipe()  // server writes, client reads
        let clientToServer = Pipe()  // client writes, server reads

        let serverTransport = StdioTransport(
            inbound:  clientToServer.fileHandleForReading,
            outbound: serverToClient.fileHandleForWriting
        )
        let clientTransport = StdioTransport(
            inbound:  serverToClient.fileHandleForReading,
            outbound: clientToServer.fileHandleForWriting
        )

        // Start the runtime — identical to any other transport.
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "stdio-demo", version: "1.0.0"),
            supportedCapabilities: Capabilities(),
            auth: BearerAuthValidator(subjectsByToken: ["demo-token": "demo"])
        )
        await runtime.register(EchoTool())
        let server = Task { try await runtime.acceptSession(over: serverTransport) }

        // Connect the client over the same NDJSON pipe transport.
        print("connecting over NDJSON pipe transport…")
        let client = try await ARCPClient.open(
            transport: clientTransport,
            auth: AuthBlock(scheme: .bearer, token: "demo-token"),
            client: IdentityBlock(kind: "stdio-demo-client", version: "1.0.0"),
            capabilities: Capabilities()
        )
        print("session open  session_id=\(client.info.sessionId.rawValue.prefix(8))")

        // Submit a tool invocation — this is a single NDJSON line on the pipe.
        let invoke = Envelope(
            sessionId: client.info.sessionId,
            payload: .toolInvoke(
                ToolInvokePayload(
                    tool: "echo",
                    arguments: .object(["message": .string("hello over stdio")])
                )
            )
        )
        try await client.send(invoke)
        print("→ tool.invoke sent (one NDJSON line on the pipe)")

        // Drain events until terminal.
        for await env in client.unhandled {
            switch env.payload {
            case .jobAccepted(let p):
                print("← job.accepted  job_id=\(p.jobId.rawValue.prefix(8))")

            case .log(let p):
                print("← log[\(p.level)]  \(p.message)")

            case .jobCompleted(let p):
                print("← job.completed  result=\(p.result?.stringValue ?? "(nil)")")
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
