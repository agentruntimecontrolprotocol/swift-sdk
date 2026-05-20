import Foundation

/// Optional lease constraints on `tool.invoke` (ARCP v1.1 §9.5).
///
/// Carries `expires_at` for time-bounded lease authority. When present,
/// the runtime MUST refuse authority-bearing operations attempted at or
/// after `expiresAt` with `LEASE_EXPIRED`.
public struct LeaseConstraints: Sendable, Codable, Hashable {
    /// UTC instant after which the lease no longer authorizes operations.
    public var expiresAt: Date

    public init(expiresAt: Date) {
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case expiresAt = "expires_at"
    }
}

/// `tool.invoke` payload. RFC §6.2 / §10.
///
/// v1.1 additions (rust-sdk pragma: typed-lease envelope is not on the
/// wire yet, so `cost.budget` and `lease_constraints` ride on this
/// payload):
///
/// - `costBudget` — `cost.budget` lease capability (ARCP v1.1 §9.6).
///   When present, the runtime tracks per-currency counters and
///   surfaces `BUDGET_EXHAUSTED` once any counter reaches zero.
/// - `leaseConstraints` — optional lease bounds (ARCP v1.1 §9.5).
///   Currently carries `expires_at` for time-bounded authority.
public struct ToolInvokePayload: Sendable, Codable, Hashable {
    public var tool: String
    public var arguments: JSONValue
    public var costBudget: CostBudget?
    public var leaseConstraints: LeaseConstraints?

    public init(
        tool: String,
        arguments: JSONValue,
        costBudget: CostBudget? = nil,
        leaseConstraints: LeaseConstraints? = nil
    ) {
        self.tool = tool
        self.arguments = arguments
        self.costBudget = costBudget
        self.leaseConstraints = leaseConstraints
    }

    enum CodingKeys: String, CodingKey {
        case tool
        case arguments
        case costBudget = "cost_budget"
        case leaseConstraints = "lease_constraints"
    }
}

/// `tool.result` payload. RFC §6.3 / §16.
public struct ToolResultPayload: Sendable, Codable, Hashable {
    public var value: JSONValue?
    public var resultRef: ArtifactRef?

    public init(value: JSONValue? = nil, resultRef: ArtifactRef? = nil) {
        self.value = value
        self.resultRef = resultRef
    }

    enum CodingKeys: String, CodingKey {
        case value
        case resultRef = "result_ref"
    }
}

/// `tool.error` payload. RFC §18.1.
public struct ToolErrorPayload: Sendable, Codable, Hashable {
    public var error: ErrorEnvelope

    public init(error: ErrorEnvelope) { self.error = error }

    public init(from decoder: any Decoder) throws {
        if let envelope = try? ErrorEnvelope(from: decoder) {
            self.error = envelope
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.error = try container.decode(ErrorEnvelope.self, forKey: .error)
    }

    public func encode(to encoder: any Encoder) throws {
        try error.encode(to: encoder)
    }

    enum CodingKeys: String, CodingKey {
        case error
    }
}

/// `job.accepted` payload. RFC §10.2.
public struct JobAcceptedPayload: Sendable, Codable, Hashable {
    public var jobId: JobId

    public init(jobId: JobId) { self.jobId = jobId }

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
    }
}

/// `job.started` payload. RFC §10.2.
public struct JobStartedPayload: Sendable, Codable, Hashable {
    public var jobId: JobId
    public var startedAt: Date

    public init(jobId: JobId, startedAt: Date = Date()) {
        self.jobId = jobId
        self.startedAt = startedAt
    }

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case startedAt = "started_at"
    }
}

/// `job.progress` payload. RFC §10.1 / v1.1 §8.2.1.
///
/// Carries the structured progress body defined in ARCP v1.1 §8.2.1:
/// - `current` — non-negative count of completed units.
/// - `total` — optional total; absent means indeterminate.
/// - `units` — optional unit label, e.g. `"files"`, `"tokens"`.
/// - `message` — optional human-readable status line.
///
/// `percent` and `attributes` are retained for backwards-compatibility with
/// earlier drafts that did not surface a structured body. New emitters
/// SHOULD populate `current` / `total` / `units` per §8.2.1.
public struct JobProgressPayload: Sendable, Codable, Hashable {
    public var current: Double?
    public var total: Double?
    public var units: String?
    public var percent: Double?
    public var message: String?
    public var attributes: [String: JSONValue]?

    public init(
        current: Double? = nil,
        total: Double? = nil,
        units: String? = nil,
        percent: Double? = nil,
        message: String? = nil,
        attributes: [String: JSONValue]? = nil
    ) {
        self.current = current
        self.total = total
        self.units = units
        self.percent = percent
        self.message = message
        self.attributes = attributes
    }

    enum CodingKeys: String, CodingKey {
        case current
        case total
        case units
        case percent
        case message
        case attributes
    }
}

/// `job.heartbeat` payload. RFC §10.3.
public struct JobHeartbeatPayload: Sendable, Codable, Hashable {
    public var sequence: Int
    public var deadlineMs: Int
    public var state: JobState

    public init(sequence: Int, deadlineMs: Int, state: JobState) {
        self.sequence = sequence
        self.deadlineMs = deadlineMs
        self.state = state
    }

    enum CodingKeys: String, CodingKey {
        case sequence
        case deadlineMs = "deadline_ms"
        case state
    }
}

/// `job.completed` payload. RFC §10.2 / ARCP v1.1 §8.4.
///
/// When the job streamed its final result via `job.result_chunk`, the
/// terminating `job.completed` MUST carry `resultId` (and SHOULD carry
/// `resultSize` and/or `summary`) instead of an inline `result`.
/// Implementations MUST NOT mix inline result and `result_chunk` for the
/// same job.
public struct JobCompletedPayload: Sendable, Codable, Hashable {
    public var result: JSONValue?
    public var resultRef: ArtifactRef?
    /// Stable identifier for a streamed result (ARCP v1.1 §8.4). Present
    /// when the job emitted `job.result_chunk` events; references the
    /// assembled chunks rather than carrying the value inline.
    public var resultId: String?
    /// Total decoded size in bytes of the streamed result. Optional;
    /// informational for clients rendering progress.
    public var resultSize: UInt64?
    /// Optional human-readable summary, typically supplied alongside a
    /// streamed result (ARCP v1.1 §8.4 / §13.6).
    public var summary: String?

    public init(
        result: JSONValue? = nil,
        resultRef: ArtifactRef? = nil,
        resultId: String? = nil,
        resultSize: UInt64? = nil,
        summary: String? = nil
    ) {
        self.result = result
        self.resultRef = resultRef
        self.resultId = resultId
        self.resultSize = resultSize
        self.summary = summary
    }

    enum CodingKeys: String, CodingKey {
        case result
        case resultRef = "result_ref"
        case resultId = "result_id"
        case resultSize = "result_size"
        case summary
    }
}

/// Encoding of `job.result_chunk.data` (ARCP v1.1 §8.4).
public enum ResultChunkEncoding: String, Sendable, Codable, Hashable, CaseIterable {
    /// Chunk payload is a UTF-8 string fragment.
    case utf8
    /// Chunk payload is a base64-encoded binary fragment.
    case base64
}

/// `job.result_chunk` payload (ARCP v1.1 §8.4).
///
/// Streams the final result of a job in ordered fragments. The agent
/// MUST emit chunks for one `resultId` in `chunkSeq` order; the
/// terminating `job.completed` references the same `resultId`.
/// Implementations MUST NOT mix inline result and `result_chunk` for
/// the same job.
public struct JobResultChunkPayload: Sendable, Codable, Hashable {
    /// Stable identifier for the assembled result. Generated by the
    /// runtime (or agent) when streaming begins.
    public var resultId: String
    /// 0-based monotonic chunk index per `resultId`.
    public var chunkSeq: UInt64
    /// Chunk payload (text or base64-encoded bytes; see `encoding`).
    public var data: String
    /// Wire-level encoding of `data`.
    public var encoding: ResultChunkEncoding
    /// `true` when more chunks follow; `false` on the terminal chunk.
    public var more: Bool

    public init(
        resultId: String,
        chunkSeq: UInt64,
        data: String,
        encoding: ResultChunkEncoding,
        more: Bool
    ) {
        self.resultId = resultId
        self.chunkSeq = chunkSeq
        self.data = data
        self.encoding = encoding
        self.more = more
    }

    enum CodingKeys: String, CodingKey {
        case resultId = "result_id"
        case chunkSeq = "chunk_seq"
        case data
        case encoding
        case more
    }
}

/// `job.failed` payload. RFC §10.2 / §18.1.
public struct JobFailedPayload: Sendable, Codable, Hashable {
    public var error: ErrorEnvelope

    public init(error: ErrorEnvelope) { self.error = error }

    public init(from decoder: any Decoder) throws {
        if let envelope = try? ErrorEnvelope(from: decoder) {
            self.error = envelope
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.error = try container.decode(ErrorEnvelope.self, forKey: .error)
    }

    public func encode(to encoder: any Encoder) throws {
        try error.encode(to: encoder)
    }

    enum CodingKeys: String, CodingKey {
        case error
    }
}

/// `job.cancelled` payload. RFC §10.4.
public struct JobCancelledPayload: Sendable, Codable, Hashable {
    public var reason: String
    public var code: ErrorCode

    public init(reason: String, code: ErrorCode = .cancelled) {
        self.reason = reason
        self.code = code
    }
}

/// Job state per RFC §10.2.
public enum JobState: String, Sendable, Codable, Hashable, CaseIterable {
    case accepted
    case queued
    case running
    case blocked
    case paused
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }
}
