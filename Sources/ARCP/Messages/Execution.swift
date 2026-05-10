import Foundation

/// `tool.invoke` payload. RFC §6.2 / §10.
public struct ToolInvokePayload: Sendable, Codable, Hashable {
    public var tool: String
    public var arguments: JSONValue

    public init(tool: String, arguments: JSONValue) {
        self.tool = tool
        self.arguments = arguments
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

/// `job.progress` payload. RFC §10.1.
public struct JobProgressPayload: Sendable, Codable, Hashable {
    public var percent: Double?
    public var message: String?
    public var attributes: [String: JSONValue]?

    public init(percent: Double? = nil, message: String? = nil, attributes: [String: JSONValue]? = nil) {
        self.percent = percent
        self.message = message
        self.attributes = attributes
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

/// `job.completed` payload. RFC §10.2.
public struct JobCompletedPayload: Sendable, Codable, Hashable {
    public var result: JSONValue?
    public var resultRef: ArtifactRef?

    public init(result: JSONValue? = nil, resultRef: ArtifactRef? = nil) {
        self.result = result
        self.resultRef = resultRef
    }

    enum CodingKeys: String, CodingKey {
        case result
        case resultRef = "result_ref"
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
