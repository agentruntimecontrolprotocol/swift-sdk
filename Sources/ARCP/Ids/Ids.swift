import Foundation

/// Newtype wrapper for an ARCP id. Conforms to `Codable` as a single string,
/// so wire compatibility is trivial. The compile-time type wall prevents
/// passing (e.g.) a `JobId` where a `SessionId` is expected.
public protocol ARCPId: Sendable, Hashable, Codable, CustomStringConvertible {
    /// Underlying canonical string form.
    var rawValue: String { get }
    init(_ rawValue: String)
}

extension ARCPId {
    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard !value.isEmpty else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "ARCP id must not be empty"
            )
        }
        self.init(value)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

private func arcpIdPrefix(_ prefix: String) -> String { prefix + "_" + Ulid.next() }

/// Identifier for an ARCP session. RFC §6.1 / §9.
public struct SessionId: ARCPId {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static func random() -> Self { Self(arcpIdPrefix("sess")) }
}

/// Identifier for an ARCP envelope. Used as the transport idempotency key. RFC §6.1 / §6.4.
public struct MessageId: ARCPId {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static func random() -> Self { Self(arcpIdPrefix("msg")) }
}

/// Identifier for a durable job. RFC §10.
public struct JobId: ARCPId {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static func random() -> Self { Self(arcpIdPrefix("job")) }
}

/// Identifier for a stream. RFC §11.
public struct StreamId: ARCPId {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static func random() -> Self { Self(arcpIdPrefix("str")) }
}

/// Identifier for a subscription. RFC §13.
public struct SubscriptionId: ARCPId {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static func random() -> Self { Self(arcpIdPrefix("sub")) }
}

/// Distributed trace id. RFC §17.1.
public struct TraceId: ARCPId {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static func random() -> Self { Self(arcpIdPrefix("trace")) }
}

/// Span id within a trace. RFC §17.1.
public struct SpanId: ARCPId {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static func random() -> Self { Self(arcpIdPrefix("span")) }
}

/// Identifier for a permission lease. RFC §15.5.
public struct LeaseId: ARCPId {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static func random() -> Self { Self(arcpIdPrefix("lease")) }
}

/// Identifier for an artifact. RFC §16.
public struct ArtifactId: ARCPId {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static func random() -> Self { Self(arcpIdPrefix("art")) }
}

/// Logical-intent idempotency key (distinct from `MessageId`). RFC §6.4.
public struct IdempotencyKey: ARCPId {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static func random() -> Self { Self(arcpIdPrefix("idem")) }
}
