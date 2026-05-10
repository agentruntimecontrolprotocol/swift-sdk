import Foundation
import Testing

@testable import ARCP

@Suite("ExtensionRegistry (RFC §21)")
struct ExtensionsTests {
    @Test("Valid arcpx namespace accepted")
    func validArcpx() throws {
        try ExtensionRegistry.validateNamespace("arcpx.acme.cache.v1")
    }

    @Test("Reverse-DNS namespace accepted")
    func validReverseDns() throws {
        try ExtensionRegistry.validateNamespace("com.acme.workflow.v2")
    }

    @Test("x- prefix is rejected")
    func rejectXPrefix() {
        #expect(throws: (any Error).self) {
            try ExtensionRegistry.validateNamespace("x-experimental")
        }
    }

    @Test("Single-segment namespace is rejected")
    func rejectSingleSegment() {
        #expect(throws: (any Error).self) {
            try ExtensionRegistry.validateNamespace("acme")
        }
    }

    @Test("Empty segment namespace is rejected")
    func rejectEmptySegment() {
        #expect(throws: (any Error).self) {
            try ExtensionRegistry.validateNamespace("arcpx..v1")
        }
    }

    @Test("Namespace extraction includes the version segment")
    func namespaceExtraction() {
        #expect(ExtensionRegistry.namespace(of: "arcpx.acme.cache.v1.warm") == "arcpx.acme.cache.v1")
        #expect(ExtensionRegistry.namespace(of: "com.acme.workflow.v2.start") == "com.acme.workflow.v2")
        #expect(ExtensionRegistry.namespace(of: "tool.invoke") == nil)
        #expect(ExtensionRegistry.namespace(of: "x-experimental") == nil)
    }

    @Test("Disposition: advertised extension accepted")
    func dispositionAccept() async {
        let registry = ExtensionRegistry(advertised: ["arcpx.acme.cache.v1"])
        let result = await registry.disposition(forUnknown: "arcpx.acme.cache.v1.warm", optional: false)
        #expect(result == .accept)
    }

    @Test("Disposition: optional + unadvertised drops")
    func dispositionDrop() async {
        let registry = ExtensionRegistry(advertised: [])
        let result = await registry.disposition(
            forUnknown: "arcpx.acme.cache.v1.warm",
            optional: true
        )
        #expect(result == .drop)
    }

    @Test("Disposition: required + unadvertised nacks")
    func dispositionNack() async {
        let registry = ExtensionRegistry(advertised: [])
        let result = await registry.disposition(
            forUnknown: "arcpx.acme.cache.v1.warm",
            optional: false
        )
        #expect(result == .nack)
    }

    @Test("Disposition: unknown core type nacks regardless of optional")
    func dispositionCoreNack() async {
        let registry = ExtensionRegistry(advertised: [])
        let optional = await registry.disposition(forUnknown: "job.checkpoint", optional: true)
        #expect(optional == .nack)
        let required = await registry.disposition(forUnknown: "job.checkpoint", optional: false)
        #expect(required == .nack)
    }
}
