import Foundation

/// Stream `kind`. RFC §11.1.
public enum StreamKind: String, Sendable, Codable, Hashable, CaseIterable {
    case text
    case binary
    case event
    case log
    case metric
    case thought
}

/// `stream.open` payload. RFC §11.1.
public struct StreamOpenPayload: Sendable, Codable, Hashable {
    public var kind: StreamKind
    public var contentType: String?
    public var encoding: String?

    public init(kind: StreamKind, contentType: String? = nil, encoding: String? = nil) {
        self.kind = kind
        self.contentType = contentType
        self.encoding = encoding
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case contentType = "content_type"
        case encoding
    }
}

/// `stream.chunk` payload. RFC §11.1 / §11.3.
public struct StreamChunkPayload: Sendable, Codable, Hashable {
    public var sequence: Int?
    public var content: String?
    public var role: String?
    public var redacted: Bool?
    public var data: String?  // base64 for binary; v0.1 always inline
    public var contentType: String?
    public var sha256: String?
    public var attributes: [String: JSONValue]?

    public init(
        sequence: Int? = nil,
        content: String? = nil,
        role: String? = nil,
        redacted: Bool? = nil,
        data: String? = nil,
        contentType: String? = nil,
        sha256: String? = nil,
        attributes: [String: JSONValue]? = nil
    ) {
        self.sequence = sequence
        self.content = content
        self.role = role
        self.redacted = redacted
        self.data = data
        self.contentType = contentType
        self.sha256 = sha256
        self.attributes = attributes
    }

    enum CodingKeys: String, CodingKey {
        case sequence, content, role, redacted, data
        case contentType = "content_type"
        case sha256, attributes
    }
}

/// `stream.close` payload. RFC §11.1.
public struct StreamClosePayload: Sendable, Codable, Hashable {
    public var reason: String?

    public init(reason: String? = nil) { self.reason = reason }
}

/// `stream.error` payload. RFC §11.1.
public struct StreamErrorPayload: Sendable, Codable, Hashable {
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
