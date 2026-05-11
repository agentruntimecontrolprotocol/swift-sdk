// ARCP runtime fronting an MCP server (RFC §20).
//
// MCP describes capabilities; ARCP operationalizes them. This bridge
// translates inbound ARCP `tool.invoke` envelopes into MCP `call_tool`
// calls against an upstream MCP server, and emits the ARCP job
// lifecycle back to the calling client.
//
//   ARCP client ──tool.invoke──> bridge ──call_tool──> MCP server
//   ARCP client <─job.{accepted,started,completed,failed}─ bridge

import ARCP
import Foundation

// Per RFC §20:
//   MCP tool schema -> ARCP capability  (advertised at session.accepted)
//   MCP tool call   -> ARCP job
//   MCP resource    -> ARCP stream of kind: event  (delegated to MCP)

/// MCP `tools/list` → namespaced ARCP capability extensions.
/// Each upstream tool surfaces as `arcpx.mcp.tool.<name>.v1` so clients
/// can negotiate which tools they require at session open.
func advertiseFromMCP(_ mcp: MCPClientSession) async throws -> [String] {
    let tools = try await mcp.listTools()
    return tools.map { "arcpx.mcp.tool.\($0.name).v1" }
}

/// Translate ARCP `tool.invoke.payload` into MCP `call_tool`. MCP errors
/// become canonical ARCP error codes.
func callViaMCP(
    _ mcp: MCPClientSession, tool: String, arguments: JSONValue
) async throws -> JSONValue {
    let result: MCPToolResult
    do {
        result = try await mcp.callTool(name: tool, arguments: arguments)
    } catch {
        throw ARCPError.internal(detail: "\(error)", cause: error)
    }
    if result.isError {
        // MCP doesn't carry a typed error code; FAILED_PRECONDITION is the
        // right canonical mapping for "tool ran, said no".
        throw ARCPError.failedPrecondition(detail: result.text)
    }
    return .object(["content": .array(result.content)])
}

/// One inbound ARCP `tool.invoke` → MCP call → ARCP job lifecycle.
func handleInvoke(
    send: @Sendable (Envelope) async throws -> Void,
    mcp: MCPClientSession,
    request: Envelope
) async throws {
    guard case .toolInvoke(let payload) = request.payload else { return }
    let jobId = JobId("job_\(UUID().uuidString.prefix(10))")

    try await send(
        Envelope(
            sessionId: request.sessionId, jobId: jobId, correlationId: request.id,
            payload: .jobAccepted(JobAcceptedPayload(jobId: jobId))
        ))
    try await send(
        Envelope(
            sessionId: request.sessionId, jobId: jobId,
            payload: .jobStarted(JobStartedPayload(jobId: jobId))
        ))

    do {
        let result = try await callViaMCP(mcp, tool: payload.tool, arguments: payload.arguments ?? .null)
        try await send(
            Envelope(
                sessionId: request.sessionId, jobId: jobId,
                payload: .jobCompleted(JobCompletedPayload(result: result))
            ))
    } catch let e as ARCPError {
        try await send(
            Envelope(
                sessionId: request.sessionId, jobId: jobId,
                payload: .jobFailed(
                    JobFailedPayload(
                        error: ErrorEnvelope(code: e.code, message: "\(e)")
                    ))
            ))
    }
}

/// Wire one MCP session as the upstream for one ARCP runtime.
func runBridge(
    send: @Sendable @escaping (Envelope) async throws -> Void,
    inbound: AsyncStream<Envelope>
) async throws {
    let mcp = try await MCPClientSession.connect(params: upstreamParams())
    defer { Task { await mcp.close() } }
    let extensions = try await advertiseFromMCP(mcp)
    // In production this list would feed `Capabilities.extensions` at the
    // runtime's `session.accepted` so clients negotiate exactly the MCP
    // tools they expect to use.
    print("bridged: \(extensions)")

    for await env in inbound {
        if case .toolInvoke = env.payload {
            try await handleInvoke(send: send, mcp: mcp, request: env)
        }
    }
}

@main
struct MCPExample {
    static func main() async throws {
        // Production version: instantiate an `ARCPRuntime`, point its
        // tool-invoke handler at `handleInvoke`, and let the WebSocket
        // transport carry inbound envelopes from real ARCP clients. We
        // elide the runtime wiring so this file stays focused on the
        // §20 translation between protocols.
        let send: @Sendable (Envelope) async throws -> Void = { _ in fatalError("elided") }
        let (inbound, _) = AsyncStream<Envelope>.makeStream()
        try await runBridge(send: send, inbound: inbound)
    }
}
