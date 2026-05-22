import Foundation
import Testing

@testable import ARCP

@Suite("model.use (ARCP v1.1 §9.7)")
struct ModelUseTests {
    @Test("matches accepts glob and prefix patterns")
    func matchesGlobPatterns() {
        let lease = ModelUse(patterns: ["tier-fast/*", "anthropic:claude-3-*"])
        #expect(lease.matches("tier-fast/sonnet"))
        #expect(lease.matches("anthropic:claude-3-haiku"))
        #expect(!lease.matches("tier-slow/opus"))
    }

    @Test("subsetViolation flags expansion")
    func subsetViolation() {
        let parent = ModelUse(patterns: ["tier-fast/*"])
        let child = ModelUse(patterns: ["tier-fast/*", "tier-slow/*"])
        #expect(parent.subsetViolation(of: child) == "tier-slow/*")
        #expect(parent.subsetViolation(of: ModelUse(patterns: ["tier-fast/sonnet"])) == nil)
    }

    @Test("Codable round-trip preserves patterns array")
    func codableRoundTrip() throws {
        let value = ModelUse(patterns: ["a/*", "b"])
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(ModelUse.self, from: encoded)
        #expect(decoded == value)
    }

    @Test("ModelUsePolicy rejects model outside lease")
    func policyRejectsMiss() {
        #expect(throws: ARCPError.self) {
            try ModelUsePolicy.check(ModelUse(patterns: ["tier-fast/*"]), model: "tier-slow/opus")
        }
    }
}
