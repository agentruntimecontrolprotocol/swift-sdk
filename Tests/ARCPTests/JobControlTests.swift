import Foundation
import Testing

@testable import ARCP

@Suite("Job cancel/interrupt control (§7.4)")
struct JobControlTests {
    private func makeManager(_ sink: EnvelopeSink) -> JobManager {
        JobManager(
            sessionId: SessionId("sess_ctrl"),
            send: { envelope in await sink.append(envelope) }
        )
    }

    @Test("Cancelling an unknown job yields a cancel.refused with JOB_NOT_FOUND")
    func cancelUnknownJob() async throws {
        let sink = EnvelopeSink()
        let manager = makeManager(sink)
        try await manager.handleCancel(
            envelope: Envelope(payload: .ping(PingPayload())),
            payload: CancelPayload(target: .job, targetId: "job_missing")
        )
        let payloads = await sink.payloads()
        guard case .cancelRefused(let refused)? = payloads.first else {
            Issue.record("expected cancel.refused, got \(payloads)")
            return
        }
        #expect(refused.code == .jobNotFound)
    }

    @Test("Interrupting an unknown job yields an explicit refusal (no silent no-op)")
    func interruptUnknownJob() async throws {
        let sink = EnvelopeSink()
        let manager = makeManager(sink)
        try await manager.handleInterrupt(
            envelope: Envelope(payload: .ping(PingPayload())),
            payload: InterruptPayload(target: .job, targetId: "job_missing", prompt: "stop")
        )
        let payloads = await sink.payloads()
        guard case .cancelRefused(let refused)? = payloads.first else {
            Issue.record("expected cancel.refused, got \(payloads)")
            return
        }
        #expect(refused.code == .jobNotFound)
    }

    @Test("Permission timeout is configurable: a never-answered request times out (#97)")
    func permissionTimeoutConfigurable() async throws {
        let sink = EnvelopeSink()
        let manager = JobManager(
            sessionId: SessionId("sess_perm"),
            permissionTimeout: .milliseconds(100),
            send: { envelope in await sink.append(envelope) }
        )
        await manager.register(PermissionRequestingTool())
        try await manager.handleToolInvoke(
            envelope: Envelope(payload: .toolInvoke(ToolInvokePayload(tool: "needs.perm", arguments: .null))),
            payload: ToolInvokePayload(tool: "needs.perm", arguments: .null)
        )
        // The handler awaits a grant that never arrives; with a 100ms
        // permissionTimeout the job must fail (not hang) well within 5s.
        var failure: ErrorEnvelope?
        for _ in 0..<50 {
            for payload in await sink.payloads() {
                if case .jobFailed(let p) = payload { failure = p.error }
            }
            if failure != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(failure?.code == .deadlineExceeded)
    }
}

private struct PermissionRequestingTool: ToolHandler {
    let name = "needs.perm"
    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        _ = try await context.requestPermission(
            permission: "fs.write",
            resource: "/tmp/x",
            operation: "write",
            reason: nil,
            leaseSeconds: 60
        )
        return .empty
    }
}
