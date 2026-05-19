import Foundation

/// `session.open` payload. RFC §8.1.
public struct SessionOpenPayload: Sendable, Codable, Hashable {
    public var auth: AuthBlock
    public var client: IdentityBlock
    public var capabilities: Capabilities

    public init(auth: AuthBlock, client: IdentityBlock, capabilities: Capabilities) {
        self.auth = auth
        self.client = client
        self.capabilities = capabilities
    }
}

/// `session.challenge` payload. RFC §8.1.
public struct SessionChallengePayload: Sendable, Codable, Hashable {
    public var nonce: String
    public var scheme: AuthScheme
    public var expiresAt: Date

    public init(nonce: String, scheme: AuthScheme, expiresAt: Date) {
        self.nonce = nonce
        self.scheme = scheme
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case nonce, scheme
        case expiresAt = "expires_at"
    }
}

/// `session.authenticate` payload. RFC §8.1.
public struct SessionAuthenticatePayload: Sendable, Codable, Hashable {
    public var auth: AuthBlock
    public var nonce: String?

    public init(auth: AuthBlock, nonce: String? = nil) {
        self.auth = auth
        self.nonce = nonce
    }
}

/// `session.accepted` payload. RFC §8.3.
public struct SessionAcceptedPayload: Sendable, Codable, Hashable {
    public var sessionId: SessionId
    public var runtime: IdentityBlock
    public var capabilities: Capabilities
    public var lease: SessionLease?

    public init(
        sessionId: SessionId,
        runtime: IdentityBlock,
        capabilities: Capabilities,
        lease: SessionLease? = nil
    ) {
        self.sessionId = sessionId
        self.runtime = runtime
        self.capabilities = capabilities
        self.lease = lease
    }

    public struct SessionLease: Sendable, Codable, Hashable {
        public var expiresAt: Date

        public init(expiresAt: Date) { self.expiresAt = expiresAt }

        enum CodingKeys: String, CodingKey {
            case expiresAt = "expires_at"
        }
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case runtime, capabilities, lease
    }
}

/// `session.unauthenticated` payload. RFC §8.
public struct SessionUnauthenticatedPayload: Sendable, Codable, Hashable {
    public var detail: String

    public init(detail: String) { self.detail = detail }
}

/// `session.rejected` payload. RFC §8.1.
public struct SessionRejectedPayload: Sendable, Codable, Hashable {
    public var error: ErrorEnvelope

    public init(error: ErrorEnvelope) { self.error = error }
}

/// `session.refresh` payload. RFC §8.4.
public struct SessionRefreshPayload: Sendable, Codable, Hashable {
    public var deadlineMs: Int

    public init(deadlineMs: Int) { self.deadlineMs = deadlineMs }

    enum CodingKeys: String, CodingKey {
        case deadlineMs = "deadline_ms"
    }
}

/// `session.evicted` payload. RFC §8.5.
public struct SessionEvictedPayload: Sendable, Codable, Hashable {
    public var reason: String
    public var code: ErrorCode

    public init(reason: String, code: ErrorCode) {
        self.reason = reason
        self.code = code
    }
}

/// `session.close` payload. RFC §9.
public struct SessionClosePayload: Sendable, Codable, Hashable {
    public var reason: String?

    public init(reason: String? = nil) { self.reason = reason }
}

/// Optional filter for `session.list_jobs`. ARCP v1.1 §6.6.
public struct SessionListJobsFilter: Sendable, Codable, Hashable {
    /// Match jobs whose current status is one of these values.
    public var status: [String]
    /// Match jobs whose agent identifier (or `agent@version`) equals this value.
    public var agent: String?
    /// Match jobs created strictly after this instant.
    public var createdAfter: Date?
    /// Match jobs created strictly before this instant.
    public var createdBefore: Date?

    public init(
        status: [String] = [],
        agent: String? = nil,
        createdAfter: Date? = nil,
        createdBefore: Date? = nil
    ) {
        self.status = status
        self.agent = agent
        self.createdAfter = createdAfter
        self.createdBefore = createdBefore
    }

    enum CodingKeys: String, CodingKey {
        case status
        case agent
        case createdAfter = "created_after"
        case createdBefore = "created_before"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.status = try c.decodeIfPresent([String].self, forKey: .status) ?? []
        self.agent = try c.decodeIfPresent(String.self, forKey: .agent)
        self.createdAfter = try c.decodeIfPresent(Date.self, forKey: .createdAfter)
        self.createdBefore = try c.decodeIfPresent(Date.self, forKey: .createdBefore)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !status.isEmpty { try c.encode(status, forKey: .status) }
        try c.encodeIfPresent(agent, forKey: .agent)
        try c.encodeIfPresent(createdAfter, forKey: .createdAfter)
        try c.encodeIfPresent(createdBefore, forKey: .createdBefore)
    }
}

/// `session.list_jobs` payload. ARCP v1.1 §6.6.
public struct SessionListJobsPayload: Sendable, Codable, Hashable {
    /// Optional filter.
    public var filter: SessionListJobsFilter?
    /// Maximum number of entries to return.
    public var limit: Int?
    /// Opaque pagination cursor returned by a previous response's `next_cursor`.
    public var cursor: String?

    public init(
        filter: SessionListJobsFilter? = nil,
        limit: Int? = nil,
        cursor: String? = nil
    ) {
        self.filter = filter
        self.limit = limit
        self.cursor = cursor
    }
}

/// One entry in `session.jobs.payload.jobs`. ARCP v1.1 §6.6.
public struct JobListEntry: Sendable, Codable, Hashable {
    public var jobId: JobId
    /// Resolved `name@version` (or bare `name` if no version was pinned).
    public var agent: String
    /// Current job status (e.g. `running`, `completed`).
    public var status: String
    /// Optional parent job id for delegated/child jobs.
    public var parentJobId: JobId?
    /// Job submission timestamp.
    public var createdAt: Date
    /// Optional trace identifier.
    public var traceId: String?
    /// Last event sequence emitted for the job in this session.
    public var lastEventSeq: UInt64

    public init(
        jobId: JobId,
        agent: String,
        status: String,
        parentJobId: JobId? = nil,
        createdAt: Date,
        traceId: String? = nil,
        lastEventSeq: UInt64 = 0
    ) {
        self.jobId = jobId
        self.agent = agent
        self.status = status
        self.parentJobId = parentJobId
        self.createdAt = createdAt
        self.traceId = traceId
        self.lastEventSeq = lastEventSeq
    }

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case agent
        case status
        case parentJobId = "parent_job_id"
        case createdAt = "created_at"
        case traceId = "trace_id"
        case lastEventSeq = "last_event_seq"
    }
}

/// `session.jobs` payload. ARCP v1.1 §6.6.
public struct SessionJobsPayload: Sendable, Codable, Hashable {
    /// Correlated request id from the matching `session.list_jobs`.
    public var requestId: String
    /// Job summaries.
    public var jobs: [JobListEntry]
    /// Opaque continuation cursor; `nil` if there are no further pages.
    public var nextCursor: String?

    public init(requestId: String, jobs: [JobListEntry], nextCursor: String? = nil) {
        self.requestId = requestId
        self.jobs = jobs
        self.nextCursor = nextCursor
    }

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case jobs
        case nextCursor = "next_cursor"
    }
}
