import Foundation

/// `ping` payload. RFC §6.2.
public struct PingPayload: Sendable, Codable, Hashable {
    public var nonce: String?

    public init(nonce: String? = nil) { self.nonce = nonce }
}

/// `pong` payload. RFC §6.2.
public struct PongPayload: Sendable, Codable, Hashable {
    public var nonce: String?

    public init(nonce: String? = nil) { self.nonce = nonce }
}

/// `ack` payload. RFC §6.3.
public struct AckPayload: Sendable, Codable, Hashable {
    public var detail: String?

    public init(detail: String? = nil) { self.detail = detail }
}

/// `nack` payload. RFC §6.3 / §18.
public struct NackPayload: Sendable, Codable, Hashable {
    public var error: ErrorEnvelope

    public init(error: ErrorEnvelope) { self.error = error }
}

/// `cancel` payload. RFC §10.4.
public struct CancelPayload: Sendable, Codable, Hashable {
    public var target: CancelTarget
    public var targetId: String
    public var reason: String?
    public var deadlineMs: Int

    public init(target: CancelTarget, targetId: String, reason: String? = nil, deadlineMs: Int = 5000) {
        self.target = target
        self.targetId = targetId
        self.reason = reason
        self.deadlineMs = deadlineMs
    }

    public enum CancelTarget: String, Sendable, Codable, Hashable {
        case job
        case stream
        case session
    }

    enum CodingKeys: String, CodingKey {
        case target
        case targetId = "target_id"
        case reason
        case deadlineMs = "deadline_ms"
    }
}

/// `cancel.accepted` payload. RFC §10.4.
public struct CancelAcceptedPayload: Sendable, Codable, Hashable {
    public var deadlineMs: Int

    public init(deadlineMs: Int) { self.deadlineMs = deadlineMs }

    enum CodingKeys: String, CodingKey {
        case deadlineMs = "deadline_ms"
    }
}

/// `cancel.refused` payload. RFC §10.4.
public struct CancelRefusedPayload: Sendable, Codable, Hashable {
    public var reason: String
    public var code: ErrorCode

    public init(reason: String, code: ErrorCode = .failedPrecondition) {
        self.reason = reason
        self.code = code
    }
}

/// `interrupt` payload. RFC §10.5.
public struct InterruptPayload: Sendable, Codable, Hashable {
    public var target: CancelPayload.CancelTarget
    public var targetId: String
    public var prompt: String

    public init(target: CancelPayload.CancelTarget, targetId: String, prompt: String) {
        self.target = target
        self.targetId = targetId
        self.prompt = prompt
    }

    enum CodingKeys: String, CodingKey {
        case target
        case targetId = "target_id"
        case prompt
    }
}

/// `resume` payload. RFC §19.
public struct ResumePayload: Sendable, Codable, Hashable {
    public var afterMessageId: MessageId?
    public var checkpointId: String?
    public var includeOpenStreams: Bool

    public init(
        afterMessageId: MessageId? = nil,
        checkpointId: String? = nil,
        includeOpenStreams: Bool = true
    ) {
        self.afterMessageId = afterMessageId
        self.checkpointId = checkpointId
        self.includeOpenStreams = includeOpenStreams
    }

    enum CodingKeys: String, CodingKey {
        case afterMessageId = "after_message_id"
        case checkpointId = "checkpoint_id"
        case includeOpenStreams = "include_open_streams"
    }
}

/// `backpressure` payload. RFC §11.2.
public struct BackpressurePayload: Sendable, Codable, Hashable {
    public var desiredRatePerSecond: Int?
    public var bufferRemainingBytes: Int?
    public var reason: String?

    public init(
        desiredRatePerSecond: Int? = nil,
        bufferRemainingBytes: Int? = nil,
        reason: String? = nil
    ) {
        self.desiredRatePerSecond = desiredRatePerSecond
        self.bufferRemainingBytes = bufferRemainingBytes
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case desiredRatePerSecond = "desired_rate_per_second"
        case bufferRemainingBytes = "buffer_remaining_bytes"
        case reason
    }
}
