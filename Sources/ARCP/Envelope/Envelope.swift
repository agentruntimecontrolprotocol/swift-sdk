import Foundation

/// Canonical ARCP message container. RFC §6.1.
///
/// Encoding uses RFC 3339 dates (`ISO8601` with fractional seconds) and the
/// snake_case key names defined in the RFC. The `payload` field is decoded by
/// dispatching on the `type` string into `MessageType.decodePayload(...)`.
public struct Envelope: Sendable, Hashable {
    public var arcp: String
    public var id: MessageId
    public var timestamp: Date
    public var source: String?
    public var target: String?
    public var sessionId: SessionId?
    public var jobId: JobId?
    public var streamId: StreamId?
    public var subscriptionId: SubscriptionId?
    public var traceId: TraceId?
    public var spanId: SpanId?
    public var parentSpanId: SpanId?
    public var correlationId: MessageId?
    public var causationId: MessageId?
    public var idempotencyKey: IdempotencyKey?
    public var priority: Priority
    public var extensions: [String: JSONValue]?
    public var payload: MessageType

    public init(
        arcp: String = ARCPVersion.wire,
        id: MessageId = .random(),
        timestamp: Date = Date(),
        source: String? = nil,
        target: String? = nil,
        sessionId: SessionId? = nil,
        jobId: JobId? = nil,
        streamId: StreamId? = nil,
        subscriptionId: SubscriptionId? = nil,
        traceId: TraceId? = nil,
        spanId: SpanId? = nil,
        parentSpanId: SpanId? = nil,
        correlationId: MessageId? = nil,
        causationId: MessageId? = nil,
        idempotencyKey: IdempotencyKey? = nil,
        priority: Priority = .default,
        extensions: [String: JSONValue]? = nil,
        payload: MessageType
    ) {
        self.arcp = arcp
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.target = target
        self.sessionId = sessionId
        self.jobId = jobId
        self.streamId = streamId
        self.subscriptionId = subscriptionId
        self.traceId = traceId
        self.spanId = spanId
        self.parentSpanId = parentSpanId
        self.correlationId = correlationId
        self.causationId = causationId
        self.idempotencyKey = idempotencyKey
        self.priority = priority
        self.extensions = extensions
        self.payload = payload
    }
}

extension Envelope: Codable {
    enum CodingKeys: String, CodingKey {
        case arcp
        case id
        case typeName = "type"
        case timestamp
        case source
        case target
        case sessionId = "session_id"
        case jobId = "job_id"
        case streamId = "stream_id"
        case subscriptionId = "subscription_id"
        case traceId = "trace_id"
        case spanId = "span_id"
        case parentSpanId = "parent_span_id"
        case correlationId = "correlation_id"
        case causationId = "causation_id"
        case idempotencyKey = "idempotency_key"
        case priority
        case extensions
        case payload
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.arcp = try container.decode(String.self, forKey: .arcp)
        self.id = try container.decode(MessageId.self, forKey: .id)
        let typeName = try container.decode(String.self, forKey: .typeName)
        self.timestamp = try Self.decodeTimestamp(from: container, forKey: .timestamp)
        self.source = try container.decodeIfPresent(String.self, forKey: .source)
        self.target = try container.decodeIfPresent(String.self, forKey: .target)
        self.sessionId = try container.decodeIfPresent(SessionId.self, forKey: .sessionId)
        self.jobId = try container.decodeIfPresent(JobId.self, forKey: .jobId)
        self.streamId = try container.decodeIfPresent(StreamId.self, forKey: .streamId)
        self.subscriptionId = try container.decodeIfPresent(SubscriptionId.self, forKey: .subscriptionId)
        self.traceId = try container.decodeIfPresent(TraceId.self, forKey: .traceId)
        self.spanId = try container.decodeIfPresent(SpanId.self, forKey: .spanId)
        self.parentSpanId = try container.decodeIfPresent(SpanId.self, forKey: .parentSpanId)
        self.correlationId = try container.decodeIfPresent(MessageId.self, forKey: .correlationId)
        self.causationId = try container.decodeIfPresent(MessageId.self, forKey: .causationId)
        self.idempotencyKey = try container.decodeIfPresent(IdempotencyKey.self, forKey: .idempotencyKey)
        self.priority = try container.decodeIfPresent(Priority.self, forKey: .priority) ?? .default
        self.extensions = try container.decodeIfPresent([String: JSONValue].self, forKey: .extensions)

        let payloadDecoder = try container.superDecoder(forKey: .payload)
        self.payload = try MessageType.decodePayload(typeName: typeName, from: payloadDecoder)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(arcp, forKey: .arcp)
        try container.encode(id, forKey: .id)
        try container.encode(payload.typeName, forKey: .typeName)
        try container.encode(Self.formatTimestamp(timestamp), forKey: .timestamp)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(target, forKey: .target)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(jobId, forKey: .jobId)
        try container.encodeIfPresent(streamId, forKey: .streamId)
        try container.encodeIfPresent(subscriptionId, forKey: .subscriptionId)
        try container.encodeIfPresent(traceId, forKey: .traceId)
        try container.encodeIfPresent(spanId, forKey: .spanId)
        try container.encodeIfPresent(parentSpanId, forKey: .parentSpanId)
        try container.encodeIfPresent(correlationId, forKey: .correlationId)
        try container.encodeIfPresent(causationId, forKey: .causationId)
        try container.encodeIfPresent(idempotencyKey, forKey: .idempotencyKey)
        try container.encode(priority, forKey: .priority)
        try container.encodeIfPresent(extensions, forKey: .extensions)
        let payloadEncoder = container.superEncoder(forKey: .payload)
        try payload.encodePayload(to: payloadEncoder)
    }
}

extension Envelope {
    /// JSON encoder configured for ARCP wire conventions.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatTimestamp(date))
        }
        return encoder
    }

    /// JSON decoder configured for ARCP wire conventions.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = parseTimestamp(raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected RFC 3339 timestamp, got \(raw)"
            )
        }
        return decoder
    }

    /// Encode the envelope as canonical JSON.
    public func toJSON() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    /// Decode an envelope from JSON.
    public static func fromJSON(_ data: Data) throws -> Envelope {
        try makeDecoder().decode(Envelope.self, from: data)
    }

    static func formatTimestamp(_ date: Date) -> String {
        Self.iso8601.string(from: date)
    }

    static func parseTimestamp(_ raw: String) -> Date? {
        if let date = iso8601.date(from: raw) { return date }
        return iso8601NoFraction.date(from: raw)
    }

    // ISO8601DateFormatter is documented as safe to *use* from multiple
    // threads after configuration; only mutation is unsafe. We configure once
    // and never mutate, so `nonisolated(unsafe)` is appropriate.
    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let iso8601NoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func decodeTimestamp(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Date {
        let raw = try container.decode(String.self, forKey: key)
        if let date = parseTimestamp(raw) { return date }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: container,
            debugDescription: "Expected RFC 3339 timestamp, got \(raw)"
        )
    }
}
