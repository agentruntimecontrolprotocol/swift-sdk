// MCP SDK shim — no first-party Swift MCP SDK exists yet (2026-Q2).
// TODO: replace with vendored bridge once `mcp-swift` stabilizes.

import ARCP

struct MCPTool: Sendable { let name: String }

struct MCPToolResult: Sendable {
    let isError: Bool
    let text: String
    let content: [JSONValue]
}

struct MCPStdioParams: Sendable {
    let command: String
    let arguments: [String]
}

actor MCPClientSession {
    static func connect(params: MCPStdioParams) async throws -> MCPClientSession {
        fatalError("elided: spawn `\\(params.command)` over stdio and initialize MCP")
    }
    func listTools() async throws -> [MCPTool] { fatalError("elided") }
    func callTool(name: String, arguments: JSONValue) async throws -> MCPToolResult {
        fatalError("elided")
    }
    func close() async { /* elided */  }
}

func upstreamParams() -> MCPStdioParams {
    MCPStdioParams(command: "python", arguments: ["-m", "mcp_server_demo"])
}
