import Foundation
import Testing

@testable import ARCP

@Suite("Artifacts (RFC §16)")
struct ArtifactTests {
    @Test("EventLog put → fetch round-trips the bytes")
    func putFetch() async throws {
        let log = try EventLog.inMemory()
        let store = ArtifactStore(eventLog: log)
        let bytes = Data("hello world".utf8)
        let ref = try await store.put(
            sessionId: SessionId("sess_a"),
            mediaType: "text/plain",
            data: bytes
        )
        #expect(ref.size == bytes.count)
        #expect(ref.sha256 != nil)
        let (fetchedRef, fetchedData) = try await store.fetch(artifactId: ref.artifactId)
        #expect(fetchedRef.artifactId == ref.artifactId)
        #expect(fetchedData == bytes)
    }

    @Test("Release deletes the artifact")
    func release() async throws {
        let log = try EventLog.inMemory()
        let store = ArtifactStore(eventLog: log)
        let ref = try await store.put(
            sessionId: SessionId("sess_a"),
            mediaType: "text/plain",
            data: Data("x".utf8)
        )
        try await store.release(artifactId: ref.artifactId)
        await #expect(throws: ARCPError.self) {
            _ = try await store.fetch(artifactId: ref.artifactId)
        }
    }

    @Test("Expired artifacts return NOT_FOUND on fetch")
    func expirationOnFetch() async throws {
        let log = try EventLog.inMemory()
        let store = ArtifactStore(eventLog: log)
        // Put with a TTL of 0 seconds: already expired.
        let ref = try await store.put(
            sessionId: SessionId("sess_a"),
            mediaType: "text/plain",
            data: Data("x".utf8),
            ttlSeconds: 0
        )
        // Wait one second to ensure expiry.
        try await Task.sleep(for: .milliseconds(50))
        await #expect(throws: ARCPError.self) {
            _ = try await store.fetch(artifactId: ref.artifactId)
        }
    }
}
