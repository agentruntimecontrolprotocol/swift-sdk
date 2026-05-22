import Foundation
import Testing

@testable import ARCP

@Suite("AgentRef (ARCP v1.1 §7.5)")
struct AgentRefTests {
    @Test("Parses a bare name")
    func parseBareName() throws {
        let r = try AgentRef.parse("code-refactor")
        #expect(r.name == "code-refactor")
        #expect(r.version == nil)
        #expect(r.wire == "code-refactor")
    }

    @Test("Parses name@version")
    func parseNameAtVersion() throws {
        let r = try AgentRef.parse("code-refactor@2.0.0")
        #expect(r.name == "code-refactor")
        #expect(r.version == "2.0.0")
        #expect(r.wire == "code-refactor@2.0.0")
    }

    @Test(
        "Wire format round-trips",
        arguments: ["a", "a-b", "a@1.0.0", "agent_x@v1.2.3+build.4", "x.y.z@1"]
    )
    func roundTrip(_ s: String) throws {
        let parsed = try AgentRef.parse(s)
        #expect(parsed.wire == s)
    }

    @Test("Rejects uppercase letters in the name")
    func rejectsUppercaseName() {
        #expect(throws: AgentRef.ParseError.self) { _ = try AgentRef.parse("CodeRefactor") }
        #expect(throws: AgentRef.ParseError.self) { _ = try AgentRef.parse("Foo@1") }
    }

    @Test("Rejects an empty version after @")
    func rejectsEmptyVersion() {
        #expect(throws: AgentRef.ParseError.self) { _ = try AgentRef.parse("ok@") }
    }

    @Test("Encodes/decodes as a single JSON string")
    func codable() throws {
        let r = try AgentRef.parse("web-research@1.0.0")
        let data = try JSONEncoder().encode(r)
        #expect(String(data: data, encoding: .utf8) == "\"web-research@1.0.0\"")
        let back = try JSONDecoder().decode(AgentRef.self, from: data)
        #expect(back == r)
    }

    @Test("Inventory accepts flat (v1.0) list of names")
    func flatInventoryDecode() throws {
        let json = "[\"code-refactor\", \"web-research\"]"
        let inv = try JSONDecoder().decode(AgentInventory.self, from: Data(json.utf8))
        guard case .flat(let names) = inv else {
            Issue.record("expected .flat, got \(inv)")
            return
        }
        #expect(names == ["code-refactor", "web-research"])
        // Re-encode preserves the flat shape.
        let back = try JSONEncoder().encode(inv)
        #expect(String(data: back, encoding: .utf8)!.contains("code-refactor"))
    }

    @Test("Inventory accepts rich (v1.1) list of entries")
    func richInventoryDecode() throws {
        let json = """
            [{"name":"code-refactor","versions":["1.0.0","2.0.0"],"default":"2.0.0"}]
            """
        let inv = try JSONDecoder().decode(AgentInventory.self, from: Data(json.utf8))
        guard case .rich(let entries) = inv else {
            Issue.record("expected .rich, got \(inv)")
            return
        }
        #expect(entries.count == 1)
        #expect(entries[0].name == "code-refactor")
        #expect(entries[0].versions == ["1.0.0", "2.0.0"])
        #expect(entries[0].default == "2.0.0")
    }

    @Test("Inventory.satisfies enforces pinned versions on rich shape")
    func satisfies() throws {
        let inv: AgentInventory = .rich([
            AgentInventoryEntry(name: "echo", versions: ["1.0.0", "2.0.0"], default: "2.0.0")
        ])
        #expect(inv.satisfies(AgentRef(name: "echo", version: nil)))
        #expect(inv.satisfies(AgentRef(name: "echo", version: "1.0.0")))
        #expect(!inv.satisfies(AgentRef(name: "echo", version: "9.9.9")))
        #expect(!inv.satisfies(AgentRef(name: "other", version: nil)))
    }

    @Test("Flat inventory matches any version since none are enumerated")
    func flatSatisfiesAnyVersion() {
        let inv: AgentInventory = .flat(["echo"])
        #expect(inv.satisfies(AgentRef(name: "echo", version: nil)))
        #expect(inv.satisfies(AgentRef(name: "echo", version: "any")))
        #expect(!inv.satisfies(AgentRef(name: "missing", version: nil)))
    }

    @Test("Capabilities round-trips with rich agents inventory")
    func capabilitiesRoundTripRichAgents() throws {
        let caps = Capabilities(
            agents: .rich([
                AgentInventoryEntry(
                    name: "code-refactor",
                    versions: ["1.0.0", "2.0.0"],
                    default: "2.0.0"
                )
            ])
        )
        let data = try JSONEncoder().encode(caps)
        let back = try JSONDecoder().decode(Capabilities.self, from: data)
        #expect(back.agents == caps.agents)
    }

    @Test("Capabilities decodes flat (v1.0) agents inventory for compat")
    func capabilitiesFlatAgents() throws {
        let json = """
            {"streaming":false,"durable_jobs":false,"checkpoints":false,
             "binary_streams":false,"agent_handoff":false,
             "artifacts":false,"subscriptions":false,"scheduled_jobs":false,
             "anonymous":false,"interrupt":false,
             "heartbeat_recovery":"fail","heartbeat_interval_seconds":30,
             "binary_encoding":["base64"],"extensions":[],
             "agents":["code-refactor","web-research"]}
            """
        let caps = try JSONDecoder().decode(Capabilities.self, from: Data(json.utf8))
        guard case .flat(let names) = caps.agents else {
            Issue.record("expected .flat agents, got \(String(describing: caps.agents))")
            return
        }
        #expect(names == ["code-refactor", "web-research"])
    }
}
