import Testing

@testable import ARCP

@Suite("Phase 0 — Scaffolding")
struct ScaffoldTests {
    @Test("Wire-protocol version is 1.0 (RFC §6.1)")
    func wireVersionIsCanonical() {
        #expect(ARCPVersion.wire == "1.0")
    }

    @Test("SDK version is set")
    func sdkVersionIsNonEmpty() {
        #expect(!ARCPVersion.sdk.isEmpty)
    }
}
