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
}
