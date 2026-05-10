import Foundation

/// Validates and tracks ARCP extension namespaces. RFC §21.
///
/// Two valid namespace forms (RFC §21.1):
/// - `arcpx.<vendor-or-domain>.<name>.v<n>`
/// - reverse-DNS prefix (e.g. `com.acme.workflow.v2`)
///
/// The bare `x-` prefix is reserved for transport-internal experiments and
/// **MUST NOT** appear in long-lived deployments — it is rejected here.
public actor ExtensionRegistry {
    private var advertised: Set<String>

    public init(advertised: [String] = []) {
        self.advertised = Set(advertised)
    }

    /// True when `namespace` was advertised in `capabilities.extensions`.
    public func isAdvertised(_ namespace: String) -> Bool {
        advertised.contains(namespace)
    }

    /// Update the advertised set after capability negotiation.
    public func setAdvertised(_ namespaces: [String]) throws {
        for namespace in namespaces {
            try Self.validateNamespace(namespace)
        }
        advertised = Set(namespaces)
    }

    /// Returns the disposition for an unknown wire `type` per RFC §21.3.
    public func disposition(forUnknown type: String, optional: Bool) -> UnknownDisposition {
        if Self.coreTypePrefixes.contains(where: { type.hasPrefix($0) }) {
            return .nack
        }
        if let namespace = Self.namespace(of: type) {
            do {
                try Self.validateNamespace(namespace)
            } catch {
                return .nack
            }
            if advertised.contains(namespace) { return .accept }
            return optional ? .drop : .nack
        }
        return .nack
    }

    /// What to do with an unknown message after applying §21.3.
    public enum UnknownDisposition: Sendable, Equatable {
        case accept
        case drop
        case nack
    }

    private static let coreTypePrefixes: [String] = [
        "session.", "ping", "pong", "ack", "nack", "cancel", "interrupt",
        "resume", "backpressure", "checkpoint.", "tool.", "job.", "workflow.",
        "agent.", "stream.", "human.", "permission.", "lease.", "subscribe",
        "unsubscribe", "artifact.", "event.", "log", "metric", "trace.",
    ]

    /// Extract a namespace prefix from a wire type, including the `vN` version
    /// segment (RFC §7 example: `arcpx.example.v1`). Returns nil if the type
    /// has no version segment or uses the reserved `x-` prefix.
    public static func namespace(of type: String) -> String? {
        if type.hasPrefix("x-") { return nil }
        guard type.contains(".") else { return nil }
        let segments = type.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        for index in (1..<segments.count).reversed() {
            let segment = segments[index]
            if segment.first == "v",
                segment.dropFirst().allSatisfy({ $0.isNumber }),
                segment.count > 1
            {
                return segments[0...index].joined(separator: ".")
            }
        }
        return nil
    }

    /// Returns true if `namespace` is a syntactically valid extension namespace.
    /// Throws `ARCPError.invalidArgument` describing the violation otherwise.
    public static func validateNamespace(_ namespace: String) throws {
        if namespace.isEmpty {
            throw ARCPError.invalidArgument(
                field: "namespace",
                detail: "Extension namespace must not be empty"
            )
        }
        if namespace.hasPrefix("x-") {
            throw ARCPError.invalidArgument(
                field: "namespace",
                detail: "x- prefix is reserved for transport-internal experiments (RFC §21.1)"
            )
        }
        let segments = namespace.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else {
            throw ARCPError.invalidArgument(
                field: "namespace",
                detail: "Namespace must contain a vendor and a name segment (RFC §21.1)"
            )
        }
        for segment in segments {
            if segment.isEmpty {
                throw ARCPError.invalidArgument(
                    field: "namespace",
                    detail: "Namespace segments must be non-empty"
                )
            }
            for character in segment {
                if !(character.isLetter || character.isNumber || character == "_" || character == "-") {
                    throw ARCPError.invalidArgument(
                        field: "namespace",
                        detail: "Invalid character in namespace: \(character)"
                    )
                }
            }
        }
    }
}
