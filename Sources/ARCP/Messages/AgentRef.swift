import Foundation

/// Parsed agent identifier per ARCP v1.1 §7.5.
///
/// Grammar (§7.5):
///
///     agent   ::= name | name "@" version
///     name    ::= [a-z0-9][a-z0-9._-]*
///     version ::= [a-zA-Z0-9.+_-]+
///
/// `version` is `nil` for a bare-name reference. Bare names resolve to the
/// runtime's advertised `default` for that agent (see
/// `Capabilities.agents`); pinned versions match exactly and surface
/// `ErrorCode.agentVersionNotAvailable` if missing.
public struct AgentRef: Sendable, Hashable, Codable, CustomStringConvertible {
    /// Bare agent name (without the `@version` suffix).
    public var name: String
    /// Optional pinned version. `nil` means "resolve to default".
    public var version: String?

    public init(name: String, version: String? = nil) {
        self.name = name
        self.version = version
    }

    /// Parse error returned by `AgentRef.parse(_:)`.
    public enum ParseError: Error, Sendable, Hashable, CustomStringConvertible {
        /// The bare-name component is empty or does not match `[a-z0-9][a-z0-9._-]*`.
        case invalidName(String)
        /// The `version` component does not match `[a-zA-Z0-9.+_-]+`.
        case invalidVersion(String)

        public var description: String {
            switch self {
            case .invalidName(let s): return "invalid agent name \"\(s)\""
            case .invalidVersion(let s): return "invalid agent version \"\(s)\""
            }
        }
    }

    /// Parse `name` or `name@version`.
    public static func parse(_ input: String) throws -> AgentRef {
        if let at = input.firstIndex(of: "@") {
            let name = String(input[..<at])
            let version = String(input[input.index(after: at)...])
            try validateName(name)
            try validateVersion(version)
            return AgentRef(name: name, version: version)
        } else {
            try validateName(input)
            return AgentRef(name: input, version: nil)
        }
    }

    /// Format back to the wire `name` or `name@version` string.
    public var wire: String {
        if let version { return "\(name)@\(version)" }
        return name
    }

    public var description: String { wire }

    private static func isNameHead(_ c: Character) -> Bool {
        c.isASCII && (c.isLowercase || c.isNumber)
    }

    private static func isNameTail(_ c: Character) -> Bool {
        c.isASCII && (c.isLowercase || c.isNumber || c == "." || c == "_" || c == "-")
    }

    private static func isVersionChar(_ c: Character) -> Bool {
        guard c.isASCII else { return false }
        if c.isLetter || c.isNumber { return true }
        return c == "." || c == "+" || c == "_" || c == "-"
    }

    private static func validateName(_ name: String) throws {
        guard let head = name.first, isNameHead(head) else {
            throw ParseError.invalidName(name)
        }
        for c in name.dropFirst() where !isNameTail(c) {
            throw ParseError.invalidName(name)
        }
    }

    private static func validateVersion(_ version: String) throws {
        guard !version.isEmpty else {
            throw ParseError.invalidVersion(version)
        }
        for c in version where !isVersionChar(c) {
            throw ParseError.invalidVersion(version)
        }
    }

    // MARK: Codable — encodes as a single string per §7.5.

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        do {
            self = try AgentRef.parse(raw)
        } catch let err as ParseError {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: err.description
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wire)
    }
}

/// One entry in the rich v1.1 form of `capabilities.agents` (ARCP v1.1 §7.5).
public struct AgentInventoryEntry: Sendable, Codable, Hashable {
    /// Agent name (matches the §7.5 `name` grammar).
    public var name: String
    /// Available versions for this agent. May be empty if the runtime
    /// advertises the agent without enumerating versions.
    public var versions: [String]
    /// Version a bare-name reference resolves to. `nil` means the
    /// runtime MAY pick any registered version (§7.5).
    public var `default`: String?

    public init(name: String, versions: [String] = [], default: String? = nil) {
        self.name = name
        self.versions = versions
        self.default = `default`
    }

    enum CodingKeys: String, CodingKey {
        case name
        case versions
        case `default`
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.versions = try c.decodeIfPresent([String].self, forKey: .versions) ?? []
        self.default = try c.decodeIfPresent(String.self, forKey: .default)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        if !versions.isEmpty { try c.encode(versions, forKey: .versions) }
        try c.encodeIfPresent(`default`, forKey: .default)
    }
}

/// Runtime-side agent inventory advertisement in `Capabilities`
/// (ARCP v1.1 §7.5).
///
/// Serializes as either a v1.0-compatible flat array of bare names or
/// the v1.1 rich array of `AgentInventoryEntry`. Both forms are
/// accepted on deserialize.
public enum AgentInventory: Sendable, Codable, Hashable {
    /// v1.0-compatible flat list of bare agent names.
    case flat([String])
    /// v1.1 rich list with versions and defaults.
    case rich([AgentInventoryEntry])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let entries = try? container.decode([AgentInventoryEntry].self) {
            self = .rich(entries)
            return
        }
        let names = try container.decode([String].self)
        self = .flat(names)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .flat(let names): try container.encode(names)
        case .rich(let entries): try container.encode(entries)
        }
    }

    /// Normalise into the rich v1.1 shape; flat entries become rich
    /// entries with empty `versions` and no `default`.
    public var asRich: [AgentInventoryEntry] {
        switch self {
        case .flat(let names):
            return names.map { AgentInventoryEntry(name: $0) }
        case .rich(let entries):
            return entries
        }
    }

    /// True if `agent` is satisfied by this inventory per §7.5 resolution
    /// rules. Bare names match any entry with that name; pinned
    /// `name@version` must appear in that entry's `versions` list. Flat
    /// (v1.0) entries match any version since the runtime does not
    /// enumerate them.
    public func satisfies(_ agent: AgentRef) -> Bool {
        switch self {
        case .flat(let names):
            return names.contains(agent.name)
        case .rich(let entries):
            return entries.contains { entry in
                guard entry.name == agent.name else { return false }
                guard let pinned = agent.version else { return true }
                return entry.versions.contains(pinned)
            }
        }
    }
}
