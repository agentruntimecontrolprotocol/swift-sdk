import Foundation

/// Idempotency caching/replay for `tool.invoke` (ARCP v1.1 §7.2).
extension JobManager {
    /// If `jobId` carries a tracked idempotency key, persist the terminal
    /// `MessageType` for future lookups by the same (principal, key).
    func persistIdempotencyIfNeeded(jobId: JobId, terminal: MessageType) async {
        guard let key = idempotencyByJob.removeValue(forKey: jobId),
            let eventLog,
            let principal = principalSubject
        else { return }
        guard let payloadValue = Self.encodePayloadBody(terminal) else { return }
        let cached: JSONValue = .object([
            "job_id": .string(jobId.rawValue),
            "type": .string(terminal.typeName),
            "payload": payloadValue,
        ])
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
        invokeId: MessageId
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
        let jobId = JobId(jobIdValue)
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
