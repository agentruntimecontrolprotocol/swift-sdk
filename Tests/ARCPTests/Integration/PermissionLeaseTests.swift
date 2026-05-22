import Foundation
import Testing

@testable import ARCP

@Suite("Permissions and leases (RFC §15)")
struct PermissionLeaseTests {
    @Test("Permission challenge → grant emits a lease and the tool succeeds")
    func challengeGrant() async throws {
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "example-runtime", version: "0.1"),
            supportedCapabilities: Capabilities(durableJobs: true),
            auth: BearerAuthValidator(subjectsByToken: ["t": "alice"])
        )
        await runtime.register(WriteTool())
        let serverTask = Task { try await runtime.acceptSession(over: pair.server) }
        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "t"),
            client: IdentityBlock(kind: "tester", version: "1"),
            capabilities: Capabilities(durableJobs: true)
        )
        await client.setPermissionHandler(GrantingPermissionHandler(seconds: 60))
        defer {
            Task {
                await client.close()
                _ = try? await serverTask.value
            }
        }
        let result = try await client.invoke(tool: "fs.write", arguments: .null)
        guard case .completed(let payload) = result.outcome else {
            Issue.record("expected completed, got \(result.outcome)")
            return
        }
        guard case .object(let dict) = payload.result,
            case .string(let leaseId) = dict["lease"]
        else {
            Issue.record("expected leaseId in result; got \(String(describing: payload.result))")
            return
        }
        #expect(leaseId.hasPrefix("lease_"))
    }

    @Test("Permission denied propagates to the tool as PERMISSION_DENIED")
    func challengeDeny() async throws {
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "example-runtime", version: "0.1"),
            supportedCapabilities: Capabilities(durableJobs: true),
            auth: BearerAuthValidator(subjectsByToken: ["t": "alice"])
        )
        await runtime.register(WriteTool())
        let serverTask = Task { try await runtime.acceptSession(over: pair.server) }
        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "t"),
            client: IdentityBlock(kind: "tester", version: "1"),
            capabilities: Capabilities(durableJobs: true)
        )
        await client.setPermissionHandler(DenyingPermissionHandler())
        defer {
            Task {
                await client.close()
                _ = try? await serverTask.value
            }
        }
        let result = try await client.invoke(tool: "fs.write", arguments: .null)
        guard case .failed(let envelope) = result.outcome else {
            Issue.record("expected failed, got \(result.outcome)")
            return
        }
        #expect(envelope.code == .permissionDenied)
    }
}

private struct WriteTool: ToolHandler {
    let name = "fs.write"
    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        let leaseId = try await context.requestPermission(
            permission: "fs.write",
            resource: "/tmp/x",
            operation: "write",
            reason: "test",
            leaseSeconds: 60
        )
        return .value(.object(["lease": .string(leaseId.rawValue)]))
    }
}

private struct GrantingPermissionHandler: PermissionHandler {
    let seconds: Int
    func handle(
        _ request: PermissionRequestPayload, jobId: JobId?
    ) async throws
        -> PermissionDecision
    {
        .granted(seconds: seconds)
    }
}

private struct DenyingPermissionHandler: PermissionHandler {
    func handle(
        _ request: PermissionRequestPayload, jobId: JobId?
    ) async throws
        -> PermissionDecision
    {
        .denied(reason: "policy")
    }
}
