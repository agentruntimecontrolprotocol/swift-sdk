import Foundation

/// Reference to an artifact. RFC §16.1.
public struct ArtifactRef: Sendable, Codable, Hashable {
    public var artifactId: ArtifactId
    public var uri: String
    public var mediaType: String
    public var size: Int
    public var sha256: String?
    public var expiresAt: Date?

    public init(
        artifactId: ArtifactId,
        uri: String,
        mediaType: String,
        size: Int,
        sha256: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.artifactId = artifactId
        self.uri = uri
        self.mediaType = mediaType
        self.size = size
        self.sha256 = sha256
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case artifactId = "artifact_id"
        case uri
        case mediaType = "media_type"
        case size, sha256
        case expiresAt = "expires_at"
    }
}

/// `artifact.put` payload. RFC §16.2.
public struct ArtifactPutPayload: Sendable, Codable, Hashable {
    public var artifactId: ArtifactId?
    public var mediaType: String
    public var data: String  // base64 (inline only in v0.1)
    public var size: Int
    public var sha256: String?
    public var ttlSeconds: Int?

    public init(
        artifactId: ArtifactId? = nil,
        mediaType: String,
        data: String,
        size: Int,
        sha256: String? = nil,
        ttlSeconds: Int? = nil
    ) {
        self.artifactId = artifactId
        self.mediaType = mediaType
        self.data = data
        self.size = size
        self.sha256 = sha256
        self.ttlSeconds = ttlSeconds
    }

    enum CodingKeys: String, CodingKey {
        case artifactId = "artifact_id"
        case mediaType = "media_type"
        case data, size, sha256
        case ttlSeconds = "ttl_seconds"
    }
}

/// `artifact.fetch` payload. RFC §16.2.
public struct ArtifactFetchPayload: Sendable, Codable, Hashable {
    public var artifactId: ArtifactId

    public init(artifactId: ArtifactId) { self.artifactId = artifactId }

    enum CodingKeys: String, CodingKey {
        case artifactId = "artifact_id"
    }
}

/// `artifact.ref` payload. RFC §16.1 / §16.2.
public struct ArtifactRefPayload: Sendable, Codable, Hashable {
    public var ref: ArtifactRef
    public var data: String?  // optional inline body; nil ⇒ fetch via uri

    public init(ref: ArtifactRef, data: String? = nil) {
        self.ref = ref
        self.data = data
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: JSONValue].self),
            dict["ref"] != nil
        {
            // legacy nested form
            let nested = try decoder.container(keyedBy: NestedKeys.self)
            self.ref = try nested.decode(ArtifactRef.self, forKey: .ref)
            self.data = try nested.decodeIfPresent(String.self, forKey: .data)
            return
        }
        // Default: ref fields inline alongside an optional `data` field.
        let nested = try decoder.container(keyedBy: NestedKeys.self)
        self.ref = try ArtifactRef(from: decoder)
        self.data = try nested.decodeIfPresent(String.self, forKey: .data)
    }

    public func encode(to encoder: any Encoder) throws {
        try ref.encode(to: encoder)
        if let data {
            var container = encoder.container(keyedBy: NestedKeys.self)
            try container.encode(data, forKey: .data)
        }
    }

    enum NestedKeys: String, CodingKey {
        case ref, data
    }
}

/// `artifact.release` payload. RFC §16.2.
public struct ArtifactReleasePayload: Sendable, Codable, Hashable {
    public var artifactId: ArtifactId

    public init(artifactId: ArtifactId) { self.artifactId = artifactId }

    enum CodingKeys: String, CodingKey {
        case artifactId = "artifact_id"
    }
}
