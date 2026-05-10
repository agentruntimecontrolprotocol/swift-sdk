import Foundation
import Testing

@testable import ARCP

@Suite("IDs (RFC §6.1)")
struct IdsTests {
    @Test("Newtype id encodes as bare string")
    func encodesAsString() throws {
        let id = SessionId("sess_abc")
        let data = try Envelope.makeEncoder().encode(id)
        let raw = String(decoding: data, as: UTF8.self)
        #expect(raw == "\"sess_abc\"")
    }

    @Test("Newtype id round-trips")
    func roundTrip() throws {
        let id = JobId("job_xyz")
        let data = try Envelope.makeEncoder().encode(id)
        let decoded = try Envelope.makeDecoder().decode(JobId.self, from: data)
        #expect(decoded == id)
    }

    @Test("Empty id rejected on decode")
    func rejectEmpty() throws {
        let data = "\"\"".data(using: .utf8)!
        #expect(throws: (any Error).self) {
            try Envelope.makeDecoder().decode(SessionId.self, from: data)
        }
    }

    @Test("Random ids carry the canonical prefix")
    func randomPrefixes() {
        #expect(SessionId.random().rawValue.hasPrefix("sess_"))
        #expect(MessageId.random().rawValue.hasPrefix("msg_"))
        #expect(JobId.random().rawValue.hasPrefix("job_"))
        #expect(StreamId.random().rawValue.hasPrefix("str_"))
        #expect(SubscriptionId.random().rawValue.hasPrefix("sub_"))
        #expect(TraceId.random().rawValue.hasPrefix("trace_"))
        #expect(SpanId.random().rawValue.hasPrefix("span_"))
        #expect(LeaseId.random().rawValue.hasPrefix("lease_"))
        #expect(ArtifactId.random().rawValue.hasPrefix("art_"))
        #expect(IdempotencyKey.random().rawValue.hasPrefix("idem_"))
    }

    @Test("ULID is 26 chars and lexicographically sortable across calls")
    func ulidMonotonic() {
        let a = Ulid.next()
        let b = Ulid.next()
        let c = Ulid.next()
        #expect(a.count == 26)
        #expect(b.count == 26)
        #expect(c.count == 26)
        #expect(a < b || a == b)
        #expect(b < c || b == c)
    }
}
