import Foundation
import Testing

@testable import ARCP

@Suite("Resume (RFC §19)")
struct ResumeTests {
    @Test("resume after_message_id replays subsequent envelopes")
    func resumeAfter() async throws {
        let log = try EventLog.inMemory()
        let session = SessionId("sess_resume")
        let earlyIds = (0..<5).map { MessageId("msg_\($0)") }
        for id in earlyIds {
            try await log.append(
                Envelope(id: id, sessionId: session, payload: .ack(AckPayload()))
            )
        }
        let replayed = try await log.replay(sessionId: session, after: MessageId("msg_2"))
        #expect(replayed.map(\.id) == [MessageId("msg_3"), MessageId("msg_4")])
    }

    @Test("resume from a missing message id throws DATA_LOSS")
    func resumeMissing() async throws {
        let log = try EventLog.inMemory()
        try await log.append(
            Envelope(
                id: MessageId("msg_present"),
                sessionId: SessionId("sess_resume2"),
                payload: .ack(AckPayload())
            )
        )
        await #expect(throws: ARCPError.self) {
            _ = try await log.replay(
                sessionId: SessionId("sess_resume2"),
                after: MessageId("msg_missing")
            )
        }
    }
}
