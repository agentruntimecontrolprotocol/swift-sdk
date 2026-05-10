import Foundation

/// `human.input.request` payload. RFC §12.1.
public struct HumanInputRequestPayload: Sendable, Codable, Hashable {
    public var prompt: String
    public var responseSchema: JSONValue?
    public var `default`: JSONValue?
    public var expiresAt: Date

    public init(
        prompt: String,
        responseSchema: JSONValue? = nil,
        default: JSONValue? = nil,
        expiresAt: Date
    ) {
        self.prompt = prompt
        self.responseSchema = responseSchema
        self.default = `default`
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case prompt
        case responseSchema = "response_schema"
        case `default`
        case expiresAt = "expires_at"
    }
}

/// `human.input.response` payload. RFC §12.1.
public struct HumanInputResponsePayload: Sendable, Codable, Hashable {
    public var value: JSONValue
    public var respondedBy: String?
    public var respondedAt: Date

    public init(value: JSONValue, respondedBy: String? = nil, respondedAt: Date = Date()) {
        self.value = value
        self.respondedBy = respondedBy
        self.respondedAt = respondedAt
    }

    enum CodingKeys: String, CodingKey {
        case value
        case respondedBy = "responded_by"
        case respondedAt = "responded_at"
    }
}

/// `human.choice.request` payload. RFC §12.2.
public struct HumanChoiceRequestPayload: Sendable, Codable, Hashable {
    public var prompt: String
    public var options: [Option]
    public var expiresAt: Date

    public init(prompt: String, options: [Option], expiresAt: Date) {
        self.prompt = prompt
        self.options = options
        self.expiresAt = expiresAt
    }

    public struct Option: Sendable, Codable, Hashable {
        public var id: String
        public var label: String

        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    enum CodingKeys: String, CodingKey {
        case prompt, options
        case expiresAt = "expires_at"
    }
}

/// `human.choice.response` payload. RFC §12.2.
public struct HumanChoiceResponsePayload: Sendable, Codable, Hashable {
    public var choiceId: String
    public var respondedBy: String?
    public var respondedAt: Date

    public init(choiceId: String, respondedBy: String? = nil, respondedAt: Date = Date()) {
        self.choiceId = choiceId
        self.respondedBy = respondedBy
        self.respondedAt = respondedAt
    }

    enum CodingKeys: String, CodingKey {
        case choiceId = "choice_id"
        case respondedBy = "responded_by"
        case respondedAt = "responded_at"
    }
}

/// `human.input.cancelled` payload. RFC §12.3 / §12.4.
public struct HumanInputCancelledPayload: Sendable, Codable, Hashable {
    public var code: ErrorCode
    public var reason: String?

    public init(code: ErrorCode = .cancelled, reason: String? = nil) {
        self.code = code
        self.reason = reason
    }
}
