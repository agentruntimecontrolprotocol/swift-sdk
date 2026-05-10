import Foundation

/// Subscription filter. RFC §13.1 / §13.2.
public struct SubscriptionFilter: Sendable, Codable, Hashable {
    public var sessionIds: [SessionId]?
    public var traceIds: [TraceId]?
    public var jobIds: [JobId]?
    public var streamIds: [StreamId]?
    public var types: [String]?
    public var minPriority: Priority?

    public init(
        sessionIds: [SessionId]? = nil,
        traceIds: [TraceId]? = nil,
        jobIds: [JobId]? = nil,
        streamIds: [StreamId]? = nil,
        types: [String]? = nil,
        minPriority: Priority? = nil
    ) {
        self.sessionIds = sessionIds
        self.traceIds = traceIds
        self.jobIds = jobIds
        self.streamIds = streamIds
        self.types = types
        self.minPriority = minPriority
    }

    enum CodingKeys: String, CodingKey {
        case sessionIds = "session_id"
        case traceIds = "trace_id"
        case jobIds = "job_id"
        case streamIds = "stream_id"
        case types
        case minPriority = "min_priority"
    }
}

/// Subscription replay window. RFC §13.3.
public struct SubscriptionSince: Sendable, Codable, Hashable {
    public var afterMessageId: MessageId?

    public init(afterMessageId: MessageId? = nil) { self.afterMessageId = afterMessageId }

    enum CodingKeys: String, CodingKey {
        case afterMessageId = "after_message_id"
    }
}

/// `subscribe` payload. RFC §13.1.
public struct SubscribePayload: Sendable, Codable, Hashable {
    public var filter: SubscriptionFilter
    public var since: SubscriptionSince?

    public init(filter: SubscriptionFilter, since: SubscriptionSince? = nil) {
        self.filter = filter
        self.since = since
    }
}

/// `subscribe.accepted` payload. RFC §13.1.
public struct SubscribeAcceptedPayload: Sendable, Codable, Hashable {
    public var subscriptionId: SubscriptionId

    public init(subscriptionId: SubscriptionId) { self.subscriptionId = subscriptionId }

    enum CodingKeys: String, CodingKey {
        case subscriptionId = "subscription_id"
    }
}

/// `subscribe.event` payload. RFC §13.1.
///
/// Carries a JSON-rendered envelope under `event`. We don't use `Envelope` directly
/// here to avoid recursive type cycles; the dispatch layer is responsible for
/// re-decoding the embedded envelope when delivering to a client.
public struct SubscribeEventPayload: Sendable, Codable, Hashable {
    public var event: JSONValue

    public init(event: JSONValue) { self.event = event }
}

/// `unsubscribe` payload. RFC §13.4.
public struct UnsubscribePayload: Sendable, Codable, Hashable {
    public var subscriptionId: SubscriptionId

    public init(subscriptionId: SubscriptionId) { self.subscriptionId = subscriptionId }

    enum CodingKeys: String, CodingKey {
        case subscriptionId = "subscription_id"
    }
}

/// `subscribe.closed` payload. RFC §13.4.
public struct SubscribeClosedPayload: Sendable, Codable, Hashable {
    public var subscriptionId: SubscriptionId
    public var code: ErrorCode
    public var reason: String?

    public init(subscriptionId: SubscriptionId, code: ErrorCode, reason: String? = nil) {
        self.subscriptionId = subscriptionId
        self.code = code
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case subscriptionId = "subscription_id"
        case code, reason
    }
}
