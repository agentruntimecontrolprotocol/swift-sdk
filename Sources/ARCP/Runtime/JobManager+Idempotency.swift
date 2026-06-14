import Foundation

/// Idempotency caching/replay for `tool.invoke` (ARCP v1.1 §7.2).
extension JobManager {
    /// If `jobId` carries a tracked idempotency key, persist the terminal
    /// `MessageType` for future lookups by the same (principal, key).
    func persistIdempotencyIfNeeded(jobId: JobId, terminal: MessageType) async {
        let fingerprint = idempotencyFingerprintByJob.removeValue(forKey: jobId)
        guard let key = idempotencyByJob.removeValue(forKey: jobId),
            let eventLog,
            let principal = principalSubject
        else { return }
        guard let payloadValue = Self.encodePayloadBody(terminal) else { return }
        var cachedFields: [String: JSONValue] = [
            "job_id": .string(jobId.rawValue),
            "type": .string(terminal.typeName),
            "payload": payloadValue,
        ]
        if let fingerprint {
            cachedFields["request_fingerprint"] = .string(fingerprint)
        }
        let cached: JSONValue = .object(cachedFields)
        let expiresAt = Date(timeIntervalSinceNow: 24 * 60 * 60)
        try? await eventLog.recordIdempotency(
            principal: principal,
            key: key,
            response: cached,
            expiresAt: expiresAt
        )
    }

    /// Replay a cached idempotency response for `key`. Returns `true` when a
    /// hit was found and emitted, `false` otherwise (caller should proceed
    /// with normal handling).
    func replayCachedIdempotency(
        key: IdempotencyKey,
        invokeId: MessageId,
        payload: ToolInvokePayload
    ) async throws -> Bool {
        guard let eventLog, let principal = principalSubject else { return false }
        guard let cached = try await eventLog.lookupIdempotency(principal: principal, key: key)
        else { return false }
        guard case .object(let dict) = cached,
            case .string(let jobIdValue) = dict["job_id"] ?? .null,
            case .string(let typeName) = dict["type"] ?? .null,
            let payloadValue = dict["payload"],
            let terminal = Self.decodePayloadBody(typeName: typeName, payload: payloadValue)
        else {
            // Cached response present but malformed — treat as miss.
            return false
        }
        // §7.2: a reused key with conflicting parameters MUST return
        // DUPLICATE_KEY; identical parameters replay the cached job.accepted.
        if case .string(let cachedFingerprint)? = dict["request_fingerprint"],
            cachedFingerprint != Self.requestFingerprint(payload)
        {
            try? await send(
                Envelope(
                    sessionId: sessionId,
                    correlationId: invokeId,
                    payload: .toolError(
                        ToolErrorPayload(
                            error: ARCPError.duplicateKey(
                                key: key.rawValue,
                                detail: "idempotency_key reused with conflicting parameters"
                            ).toEnvelope()
                        )
                    )
                )
            )
            return true
        }
        let jobId = JobId(jobIdValue)
        // §7.2 / §9.8.2: the replayed job.accepted matches the original's
        // non-secret fields (same job_id). Credentials are deliberately nil:
        // the original credentials were revoked when the job terminated
        // (§9.8.2) and are never persisted (§14), so they cannot — and must
        // not — be re-emitted on replay. This is the defined, tested behavior
        // for credential-bearing idempotent replays.
        try? await send(
            Envelope(
                sessionId: sessionId,
                jobId: jobId,
                correlationId: invokeId,
                payload: .jobAccepted(JobAcceptedPayload(jobId: jobId, credentials: nil))
            )
        )
        try? await send(
            Envelope(
                sessionId: sessionId,
                jobId: jobId,
                correlationId: invokeId,
                payload: terminal
            )
        )
        return true
    }

    /// Deterministic fingerprint of a `tool.invoke`'s parameters (tool,
    /// arguments, cost.budget, model.use, lease_constraints, max_runtime_sec)
    /// used to detect conflicting idempotency-key reuse (§7.2). The encoder
    /// uses sorted keys, so equal parameters always yield equal fingerprints.
    static func requestFingerprint(_ payload: ToolInvokePayload) -> String {
        guard let data = try? Envelope.makeEncoder().encode(payload),
            let string = String(data: data, encoding: .utf8)
        else {
            return "\(payload.tool)"
        }
        return string
    }

    /// Encode a `MessageType` payload body as JSON (just the payload object —
    /// the `type` discriminant is stored separately).
    static func encodePayloadBody(_ payload: MessageType) -> JSONValue? {
        let envelope = Envelope(payload: payload)
        guard let data = try? envelope.toJSON(),
            let value = try? Envelope.makeDecoder().decode(JSONValue.self, from: data),
            case .object(let dict) = value
        else { return nil }
        return dict["payload"]
    }

    /// Decode a payload body previously written with `encodePayloadBody`,
    /// using `typeName` as the dispatch discriminant.
    static func decodePayloadBody(
        typeName: String,
        payload: JSONValue
    ) -> MessageType? {
        let synthetic: JSONValue = .object([
            "arcp": .string("1.1"),
            "id": .string("idempotency_replay"),
            "type": .string(typeName),
            "timestamp": .string(ISO8601DateFormatter().string(from: Date())),
            "payload": payload,
        ])
        guard let data = try? Envelope.makeEncoder().encode(synthetic),
            let envelope = try? Envelope.makeDecoder().decode(Envelope.self, from: data)
        else { return nil }
        return envelope.payload
    }
}
