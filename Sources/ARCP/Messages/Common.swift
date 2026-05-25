import Foundation

/// Negotiated client/runtime capabilities. RFC §7.
public struct Capabilities: Sendable, Codable, Hashable {
    /// Whether the peer supports multi-kind streams (RFC §11).
    public var streaming: Bool
    /// Whether the peer supports durable-job semantics (RFC §10).
    public var durableJobs: Bool
    /// Whether the peer supports checkpointed resume (RFC §19) — currently
    /// not implemented in this SDK.
    public var checkpoints: Bool
    /// Whether the peer supports binary stream frames (RFC §11.3).
    public var binaryStreams: Bool
    /// Whether the peer supports cross-agent handoff (RFC §14).
    public var agentHandoff: Bool
    /// Whether inline-base64 artifacts are supported (RFC §16).
    public var artifacts: Bool
    /// Whether subscriptions are supported (RFC §13).
    public var subscriptions: Bool
    /// Whether the peer supports scheduled jobs (RFC §14) — currently not
    /// implemented.
    public var scheduledJobs: Bool
    /// Whether `scheme=none` (anonymous) handshakes are accepted.
    public var anonymous: Bool
    /// Whether the peer advertises the `interrupt` control flow. **Leave
    /// `false`** in this SDK release — see [Interrupts in the jobs
    /// guide](https://github.com/agentruntimecontrolprotocol/swift-sdk/blob/main/docs/guides/jobs.md);
    /// the runtime acks interrupts but does not surface them to handlers.
    public var interrupt: Bool
    /// Whether `job.result_chunk` streaming is supported (RFC §8.4).
    public var resultChunk: Bool
    /// Whether `cost.budget` accounting is supported (RFC §9.6).
    public var costBudget: Bool
    /// Whether `model.use` lease pattern enforcement is supported (RFC §9.7).
    public var modelUse: Bool
    /// Whether provisioned-credential issuance is supported (RFC §9.8).
    public var provisionedCredentials: Bool
    /// Heartbeat recovery policy (RFC §10.3). **Heartbeat ack tracking is
    /// not implemented in this release** — heartbeats are telemetry only.
    public var heartbeatRecovery: HeartbeatRecovery
    /// Heartbeat interval in seconds.
    public var heartbeatIntervalSeconds: Int
    /// Accepted binary stream encodings.
    public var binaryEncoding: [BinaryEncoding]
    /// Artifact retention policy (RFC §16.3).
    public var artifactRetention: ArtifactRetention?
    /// Negotiated set of advertised extension namespaces (RFC §21).
    public var extensions: [String]
    /// Free-form extras the spec does not enumerate.
    public var extras: [String: Bool]
    /// Runtime-side advertisement of available agents (ARCP v1.1 §7.5).
    /// Accepts both v1.0 flat-name and v1.1 rich shapes.
    public var agents: AgentInventory?

    public init(
        streaming: Bool = false,
        durableJobs: Bool = false,
        checkpoints: Bool = false,
        binaryStreams: Bool = false,
        agentHandoff: Bool = false,
        artifacts: Bool = false,
        subscriptions: Bool = false,
        scheduledJobs: Bool = false,
        anonymous: Bool = false,
        interrupt: Bool = false,
        resultChunk: Bool = false,
        costBudget: Bool = false,
        modelUse: Bool = false,
        provisionedCredentials: Bool = false,
        heartbeatRecovery: HeartbeatRecovery = .fail,
        heartbeatIntervalSeconds: Int = 30,
        binaryEncoding: [BinaryEncoding] = [.base64],
        artifactRetention: ArtifactRetention? = nil,
        extensions: [String] = [],
        extras: [String: Bool] = [:],
        agents: AgentInventory? = nil
    ) {
        self.streaming = streaming
        self.durableJobs = durableJobs
        self.checkpoints = checkpoints
        self.binaryStreams = binaryStreams
        self.agentHandoff = agentHandoff
        self.artifacts = artifacts
        self.subscriptions = subscriptions
        self.scheduledJobs = scheduledJobs
        self.anonymous = anonymous
        self.interrupt = interrupt
        self.resultChunk = resultChunk
        self.costBudget = costBudget
        self.modelUse = modelUse
        self.provisionedCredentials = provisionedCredentials
        self.heartbeatRecovery = heartbeatRecovery
        self.heartbeatIntervalSeconds = heartbeatIntervalSeconds
        self.binaryEncoding = binaryEncoding
        self.artifactRetention = artifactRetention
        self.extensions = extensions
        self.extras = extras
        self.agents = agents
    }

    public enum HeartbeatRecovery: String, Sendable, Codable, Hashable {
        case fail
        case block
    }

    public enum BinaryEncoding: String, Sendable, Codable, Hashable {
        case base64
        case sidecar
    }

    public struct ArtifactRetention: Sendable, Codable, Hashable {
        public var defaultSeconds: Int
        public var maxSeconds: Int

        public init(defaultSeconds: Int, maxSeconds: Int) {
            self.defaultSeconds = defaultSeconds
            self.maxSeconds = maxSeconds
        }

        enum CodingKeys: String, CodingKey {
            case defaultSeconds = "default_seconds"
            case maxSeconds = "max_seconds"
        }
    }

    private static let knownKeys: Set<String> = [
        "streaming", "durable_jobs", "checkpoints", "binary_streams", "agent_handoff",
        "artifacts", "subscriptions", "scheduled_jobs", "anonymous",
        "interrupt", "result_chunk", "cost_budget", "cost.budget", "model_use", "model.use",
        "provisioned_credentials", "heartbeat_recovery", "heartbeat_interval_seconds",
        "binary_encoding", "artifact_retention", "extensions", "agents",
    ]

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        func decodeBool(_ key: String, default fallback: Bool = false) -> Bool {
            ((try? container.decodeIfPresent(Bool.self, forKey: DynamicKey(stringValue: key)))
                ?? nil) ?? fallback
        }
        self.streaming = decodeBool("streaming")
        self.durableJobs = decodeBool("durable_jobs")
        self.checkpoints = decodeBool("checkpoints")
        self.binaryStreams = decodeBool("binary_streams")
        self.agentHandoff = decodeBool("agent_handoff")
        self.artifacts = decodeBool("artifacts")
        self.subscriptions = decodeBool("subscriptions")
        self.scheduledJobs = decodeBool("scheduled_jobs")
        self.anonymous = decodeBool("anonymous")
        self.interrupt = decodeBool("interrupt")
        self.resultChunk = decodeBool("result_chunk")
        self.costBudget = decodeBool("cost_budget") || decodeBool("cost.budget")
        self.modelUse = decodeBool("model_use") || decodeBool("model.use")
        self.provisionedCredentials = decodeBool("provisioned_credentials")
        self.heartbeatRecovery =
            ((try? container.decodeIfPresent(
                HeartbeatRecovery.self,
                forKey: DynamicKey(stringValue: "heartbeat_recovery")
            )) ?? nil) ?? .fail
        self.heartbeatIntervalSeconds =
            ((try? container.decodeIfPresent(
                Int.self,
                forKey: DynamicKey(stringValue: "heartbeat_interval_seconds")
            )) ?? nil) ?? 30
        self.binaryEncoding =
            ((try? container.decodeIfPresent(
                [BinaryEncoding].self,
                forKey: DynamicKey(stringValue: "binary_encoding")
            )) ?? nil) ?? [.base64]
        self.artifactRetention = try container.decodeIfPresent(
            ArtifactRetention.self,
            forKey: DynamicKey(stringValue: "artifact_retention")
        )
        self.extensions =
            ((try? container.decodeIfPresent(
                [String].self,
                forKey: DynamicKey(stringValue: "extensions")
            )) ?? nil) ?? []
        self.agents = try container.decodeIfPresent(
            AgentInventory.self,
            forKey: DynamicKey(stringValue: "agents")
        )
        var extras: [String: Bool] = [:]
        for key in container.allKeys where !Self.knownKeys.contains(key.stringValue) {
            if let value = try? container.decode(Bool.self, forKey: key) {
                extras[key.stringValue] = value
            }
        }
        self.extras = extras
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        try container.encode(streaming, forKey: DynamicKey(stringValue: "streaming"))
        try container.encode(durableJobs, forKey: DynamicKey(stringValue: "durable_jobs"))
        try container.encode(checkpoints, forKey: DynamicKey(stringValue: "checkpoints"))
        try container.encode(binaryStreams, forKey: DynamicKey(stringValue: "binary_streams"))
        try container.encode(agentHandoff, forKey: DynamicKey(stringValue: "agent_handoff"))
        try container.encode(artifacts, forKey: DynamicKey(stringValue: "artifacts"))
        try container.encode(subscriptions, forKey: DynamicKey(stringValue: "subscriptions"))
        try container.encode(scheduledJobs, forKey: DynamicKey(stringValue: "scheduled_jobs"))
        try container.encode(anonymous, forKey: DynamicKey(stringValue: "anonymous"))
        try container.encode(interrupt, forKey: DynamicKey(stringValue: "interrupt"))
        try container.encode(resultChunk, forKey: DynamicKey(stringValue: "result_chunk"))
        try container.encode(costBudget, forKey: DynamicKey(stringValue: "cost_budget"))
        try container.encode(modelUse, forKey: DynamicKey(stringValue: "model_use"))
        try container.encode(
            provisionedCredentials,
            forKey: DynamicKey(stringValue: "provisioned_credentials")
        )
        try container.encode(heartbeatRecovery, forKey: DynamicKey(stringValue: "heartbeat_recovery"))
        try container.encode(
            heartbeatIntervalSeconds,
            forKey: DynamicKey(stringValue: "heartbeat_interval_seconds")
        )
        try container.encode(binaryEncoding, forKey: DynamicKey(stringValue: "binary_encoding"))
        try container.encodeIfPresent(
            artifactRetention,
            forKey: DynamicKey(stringValue: "artifact_retention")
        )
        try container.encode(extensions, forKey: DynamicKey(stringValue: "extensions"))
        try container.encodeIfPresent(agents, forKey: DynamicKey(stringValue: "agents"))
        for (key, value) in extras {
            try container.encode(value, forKey: DynamicKey(stringValue: key))
        }
    }
}

/// Authentication credentials carried in `session.open` / `session.authenticate`. RFC §8.2.
public struct AuthBlock: Sendable, Codable, Hashable {
    public var scheme: AuthScheme
    public var token: String?

    public init(scheme: AuthScheme, token: String? = nil) {
        self.scheme = scheme
        self.token = token
    }
}

/// Wire-level auth scheme name. RFC §8.2.
public enum AuthScheme: String, Sendable, Codable, Hashable {
    case bearer
    case mtls
    case oauth2
    case signedJwt = "signed_jwt"
    case none
}

/// Identity attestation block. RFC §8.2 / §8.3.
public struct IdentityBlock: Sendable, Codable, Hashable {
    public var kind: String
    public var version: String
    public var fingerprint: String?
    public var principal: String?
    public var trustLevel: TrustLevel?

    public init(
        kind: String,
        version: String,
        fingerprint: String? = nil,
        principal: String? = nil,
        trustLevel: TrustLevel? = nil
    ) {
        self.kind = kind
        self.version = version
        self.fingerprint = fingerprint
        self.principal = principal
        self.trustLevel = trustLevel
    }

    enum CodingKeys: String, CodingKey {
        case kind, version, fingerprint, principal
        case trustLevel = "trust_level"
    }
}

/// Trust classifications. RFC §15.3.
public enum TrustLevel: String, Sendable, Codable, Hashable {
    case untrusted
    case constrained
    case trusted
    case privileged
}

/// Envelope-shape error body shared by `tool.error`, `job.failed`, `nack`, etc. RFC §18.1.
public struct ErrorEnvelope: Sendable, Codable, Hashable {
    public var code: ErrorCode
    public var message: String
    public var retryable: Bool?
    public var details: [String: JSONValue]?
    public var cause: ErrorEnvelopeBox?
    public var traceId: TraceId?

    public init(
        code: ErrorCode,
        message: String,
        retryable: Bool? = nil,
        details: [String: JSONValue]? = nil,
        cause: ErrorEnvelopeBox? = nil,
        traceId: TraceId? = nil
    ) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.details = details
        self.cause = cause
        self.traceId = traceId
    }

    enum CodingKeys: String, CodingKey {
        case code, message, retryable, details, cause
        case traceId = "trace_id"
    }
}

/// Boxed indirect form for `cause` chaining.
public indirect enum ErrorEnvelopeBox: Sendable, Codable, Hashable {
    case error(ErrorEnvelope)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let envelope = try container.decode(ErrorEnvelope.self)
        self = .error(envelope)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .error(let envelope): try container.encode(envelope)
        }
    }

    public var unwrap: ErrorEnvelope {
        switch self {
        case .error(let envelope): return envelope
        }
    }
}

extension ARCPError {
    /// Convert to a wire-shape error envelope.
    public func toEnvelope(traceId: TraceId? = nil) -> ErrorEnvelope {
        ErrorEnvelope(
            code: code,
            message: message,
            retryable: isRetryable,
            details: details.isEmpty ? nil : details,
            cause: nil,
            traceId: traceId
        )
    }
}
