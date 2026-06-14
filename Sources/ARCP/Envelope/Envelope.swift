import Foundation

/// Canonical ARCP message container. RFC §6.1.
///
/// Encoding uses RFC 3339 dates (`ISO8601` with fractional seconds) and the
/// snake_case key names defined in the RFC. The `payload` field is decoded by
/// dispatching on the `type` string into `MessageType.decodePayload(...)`.
public struct Envelope: Sendable, Hashable {
    /// ARCP wire-version string (e.g. `"1.1"`). RFC §6.1.
    public var arcp: String
    /// Globally unique message identifier (ULID). RFC §6.1.
    public var id: MessageId
    /// Wall-clock creation timestamp.
    public var timestamp: Date
    /// Free-form sender identifier (typically a deployment name).
    public var source: String?
    /// Free-form recipient identifier.
    public var target: String?
    /// Session this message belongs to. Required for any envelope persisted
    /// to the event log.
    public var sessionId: SessionId?
    /// Job this message belongs to, if any. RFC §7.
    public var jobId: JobId?
    /// Stream this message belongs to, if any. RFC §11.
    public var streamId: StreamId?
    /// Subscription this message belongs to, if any. RFC §13.
    public var subscriptionId: SubscriptionId?
    /// Distributed-trace identifier (RFC §17.1). Inherits ambient
    /// `Tracing.current` if not explicitly set.
    public var traceId: TraceId?
    /// Span identifier for this envelope (RFC §17.1).
    public var spanId: SpanId?
    /// Parent span identifier (RFC §17.1).
    public var parentSpanId: SpanId?
    /// Identifier of the request this envelope responds to (RFC §6.1).
    public var correlationId: MessageId?
    /// Identifier of the envelope that caused this one to be emitted.
    public var causationId: MessageId?
    /// Idempotency key for tool-invocation retry safety (RFC §6.4).
    public var idempotencyKey: IdempotencyKey?
    /// Session-scoped, strictly-monotonic, gap-free sequence number stamped
    /// on job-event envelopes by the runtime (ARCP v1.1 §5 / §8.3). Clients
    /// use it to detect gaps and drive resume. `nil` on non-event envelopes
    /// (handshake, control) that are not part of the ordered event stream.
    public var eventSeq: UInt64?
    /// Priority hint for transports and subscription filters.
    public var priority: Priority
    /// Free-form extension fields (RFC §21).
    public var extensions: [String: JSONValue]?
    /// The strongly-typed payload (`type` + body) carried by the envelope.
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
        eventSeq: UInt64? = nil,
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
        // When trace fields are not explicitly set, inherit them from the
        // ambient `Tracing.current` task-local context. The observability
        // guide promises envelopes built inside `Tracing.withTrace` propagate
        // the trace automatically (RFC §17.1).
        if let trace = Tracing.current {
            self.traceId = traceId ?? trace.traceId
            self.spanId = spanId ?? trace.spanId
            self.parentSpanId = parentSpanId ?? trace.parentSpanId
        } else {
            self.traceId = traceId
            self.spanId = spanId
            self.parentSpanId = parentSpanId
        }
        self.correlationId = correlationId
        self.causationId = causationId
        self.idempotencyKey = idempotencyKey
        self.eventSeq = eventSeq
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
        case eventSeq = "event_seq"
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
        self.eventSeq = try container.decodeIfPresent(UInt64.self, forKey: .eventSeq)
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
        try container.encodeIfPresent(eventSeq, forKey: .eventSeq)
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
