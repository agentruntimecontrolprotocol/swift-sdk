import Foundation

/// Log level. RFC §17.2.
public enum LogLevel: String, Sendable, Codable, Hashable, CaseIterable {
    case trace
    case debug
    case info
    case warn
    case error
    case critical
}

/// `event.emit` payload. RFC §6.2 / §13.3.
///
/// Used both for user-emitted events and the synthetic
/// `subscription.backfill_complete` boundary marker.
public struct EventEmitPayload: Sendable, Codable, Hashable {
    public var name: String
    public var attributes: [String: JSONValue]?

    public init(name: String, attributes: [String: JSONValue]? = nil) {
        self.name = name
        self.attributes = attributes
    }
}

/// `log` payload. RFC §17.2.
public struct LogPayload: Sendable, Codable, Hashable {
    public var level: LogLevel
    public var message: String
    public var attributes: [String: JSONValue]?

    public init(level: LogLevel, message: String, attributes: [String: JSONValue]? = nil) {
        self.level = level
        self.message = message
        self.attributes = attributes
    }
}

/// `metric` payload. RFC §17.3.
public struct MetricPayload: Sendable, Codable, Hashable {
    public var name: String
    public var value: Double
    public var unit: String?
    public var dims: [String: JSONValue]?

    public init(name: String, value: Double, unit: String? = nil, dims: [String: JSONValue]? = nil) {
        self.name = name
        self.value = value
        self.unit = unit
        self.dims = dims
    }
}

/// `trace.span` payload. RFC §17.1.
public struct TraceSpanPayload: Sendable, Codable, Hashable {
    public var name: String
    public var startedAt: Date
    public var endedAt: Date?
    public var attributes: [String: JSONValue]?
    public var status: String?

    public init(
        name: String,
        startedAt: Date,
        endedAt: Date? = nil,
        attributes: [String: JSONValue]? = nil,
        status: String? = nil
    ) {
        self.name = name
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.attributes = attributes
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case name
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case attributes, status
    }
}

/// Reserved metric names per RFC §17.3.1. Runtimes producing these concepts
/// **MUST** use these names with the indicated units.
public enum StandardMetric {
    public static let tokensUsed = "tokens.used"
    public static let costUsd = "cost.usd"
    public static let gpuSeconds = "gpu.seconds"
    public static let toolInvocations = "tool.invocations"
    public static let latencyMs = "latency.ms"
    public static let bytesIn = "bytes.in"
    public static let bytesOut = "bytes.out"
    public static let errorsTotal = "errors.total"

    public static let allReserved: Set<String> = [
        tokensUsed, costUsd, gpuSeconds, toolInvocations, latencyMs,
        bytesIn, bytesOut, errorsTotal,
    ]

    /// Canonical unit per §17.3.1.
    public static func unit(for name: String) -> String? {
        switch name {
        case tokensUsed: return "tokens"
        case costUsd: return "usd"
        case gpuSeconds: return "seconds"
        case toolInvocations, errorsTotal: return "count"
        case latencyMs: return "ms"
        case bytesIn, bytesOut: return "bytes"
        default: return nil
        }
    }
}
