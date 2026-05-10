import Foundation
import Testing

@testable import ARCP

@Suite("EventLog (RFC §6.4 / §13.3 / §19)")
struct EventLogTests {
    @Test("Append + replay round-trips the envelope")
    func appendAndReplay() async throws {
        let log = try EventLog.inMemory()
        let envelope = Envelope(
            sessionId: SessionId("sess_a"),
            payload: .ack(AckPayload(detail: "ok"))
        )
        let inserted = try await log.append(envelope)
        #expect(inserted == true)
        let replayed = try await log.replay(sessionId: SessionId("sess_a"))
        #expect(replayed.count == 1)
        #expect(replayed[0].id == envelope.id)
    }

    @Test("Duplicate (session_id, message_id) is silently ignored")
    func duplicateDedup() async throws {
        let log = try EventLog.inMemory()
        let envelope = Envelope(
            id: MessageId("msg_dup"),
            sessionId: SessionId("sess_a"),
            payload: .ping(PingPayload())
        )
        let first = try await log.append(envelope)
        let second = try await log.append(envelope)
        #expect(first == true)
        #expect(second == false)
        let count = try await log.count(for: SessionId("sess_a"))
        #expect(count == 1)
    }

    @Test("Replay is ordered by insertion sequence")
    func replayOrder() async throws {
        let log = try EventLog.inMemory()
        let session = SessionId("sess_b")
        let ids = (0..<10).map { MessageId("msg_\($0)") }
        for id in ids {
            try await log.append(
                Envelope(id: id, sessionId: session, payload: .ack(AckPayload()))
            )
        }
        let replayed = try await log.replay(sessionId: session)
        #expect(replayed.map(\.id) == ids)
    }

    @Test("Replay from `after` skips earlier entries")
    func replayAfter() async throws {
        let log = try EventLog.inMemory()
        let session = SessionId("sess_c")
        for i in 0..<5 {
            try await log.append(
                Envelope(
                    id: MessageId("msg_\(i)"),
                    sessionId: session,
                    payload: .ack(AckPayload())
                )
            )
        }
        let replayed = try await log.replay(
            sessionId: session,
            after: MessageId("msg_2")
        )
        #expect(replayed.map(\.id) == [MessageId("msg_3"), MessageId("msg_4")])
    }

    @Test("Replay from missing message id throws DATA_LOSS (RFC §19)")
    func replayUnknownAfter() async throws {
        let log = try EventLog.inMemory()
        try await log.append(
            Envelope(
                id: MessageId("msg_present"),
                sessionId: SessionId("sess_d"),
                payload: .ack(AckPayload())
            )
        )
        await #expect(throws: ARCPError.self) {
            _ = try await log.replay(
                sessionId: SessionId("sess_d"),
                after: MessageId("msg_missing")
            )
        }
    }

    @Test("Append rejects envelope without session_id")
    func requireSessionId() async throws {
        let log = try EventLog.inMemory()
        let envelope = Envelope(payload: .ping(PingPayload()))
        await #expect(throws: ARCPError.self) {
            _ = try await log.append(envelope)
        }
    }

    @Test("Idempotency record stores and looks up by (principal, key)")
    func idempotencyLookup() async throws {
        let log = try EventLog.inMemory()
        let key = IdempotencyKey("refund-ord_4812")
        try await log.recordIdempotency(
            principal: "alice",
            key: key,
            response: .object(["ok": .bool(true)]),
            expiresAt: Date(timeIntervalSinceNow: 3_600)
        )
        let found = try await log.lookupIdempotency(principal: "alice", key: key)
        #expect(found == .object(["ok": .bool(true)]))
        let missing = try await log.lookupIdempotency(principal: "bob", key: key)
        #expect(missing == nil)
    }
}
