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

    // Issue #53 regressions: parent wildcards with required suffix segments
    // must not be treated as covering child patterns that escape the suffix.

    @Test("subsetViolation rejects gpt-5 under gpt-*o parent")
    func subsetViolationSuffixed() {
        let parent = ModelUse(patterns: ["openai:gpt-*o"])
        let child = ModelUse(patterns: ["openai:gpt-5"])
        #expect(parent.subsetViolation(of: child) == "openai:gpt-5")
    }

    @Test("subsetViolation rejects cross-segment escape")
    func subsetViolationCrossSegment() {
        let parent = ModelUse(patterns: ["tier-*/sonnet"])
        let child = ModelUse(patterns: ["tier-fast/opus"])
        #expect(parent.subsetViolation(of: child) == "tier-fast/opus")
    }

    @Test("subsetViolation accepts true subset glob")
    func subsetViolationTrueSubset() {
        let parent = ModelUse(patterns: ["openai:gpt-*"])
        let child = ModelUse(patterns: ["openai:gpt-4o"])
        #expect(parent.subsetViolation(of: child) == nil)
    }

    @Test("subsetViolation handles global wildcard")
    func subsetViolationGlobal() {
        let parent = ModelUse(patterns: ["*"])
        let child = ModelUse(patterns: ["anything", "tier-fast/*"])
        #expect(parent.subsetViolation(of: child) == nil)
    }

    @Test("subsetViolation rejects child wildcard not covered by parent suffix")
    func subsetViolationChildWildcardNotCovered() {
        let parent = ModelUse(patterns: ["openai:gpt-*o"])
        let child = ModelUse(patterns: ["openai:gpt-*"])
        // Child can match openai:gpt-5 which parent cannot match.
        #expect(parent.subsetViolation(of: child) == "openai:gpt-*")
    }
}
