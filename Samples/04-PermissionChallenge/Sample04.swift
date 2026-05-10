import ARCP
import Foundation

/// Sample 04 — tool requests a permission, client grants it with a 60s lease,
/// tool succeeds and returns the lease id.
@main
struct Sample04PermissionChallenge {
    static func main() async throws {
        print("Sample 04 — permission challenge (wire \(ARCPVersion.wire))")
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "sample-runtime", version: ARCPVersion.sdk),
            supportedCapabilities: Capabilities(durableJobs: true, humanInput: true),
            auth: BearerAuthValidator(subjectsByToken: ["demo": "alice"])
        )
        await runtime.register(WriterTool())
        let serverTask = Task { try await runtime.acceptSession(over: pair.server) }

        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "demo"),
            client: IdentityBlock(kind: "sample-client", version: ARCPVersion.sdk),
            capabilities: Capabilities(durableJobs: true, humanInput: true)
        )
        await client.setPermissionHandler(GrantHandler())

        let result = try await client.invoke(tool: "writeFile", arguments: .null)
        if case .completed(let payload) = result.outcome {
            print("write succeeded: \(String(describing: payload.result))")
        }
        await client.close()
        _ = try await serverTask.value
    }
}

private struct WriterTool: ToolHandler {
    let name = "writeFile"
    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        let leaseId = try await context.requestPermission(
            permission: "fs.write",
            resource: "/tmp/sample.txt",
            operation: "write",
            reason: "demo write",
            leaseSeconds: 60
        )
        return .value(.object(["lease": .string(leaseId.rawValue)]))
    }
}

private struct GrantHandler: PermissionHandler {
    func handle(
        _ request: PermissionRequestPayload, jobId: JobId?
    ) async throws
        -> PermissionDecision
    {
        print("→ runtime asks for: \(request.permission) on \(request.resource)")
        return .granted(seconds: 60)
    }
}
