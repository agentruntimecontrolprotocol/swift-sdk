import Foundation
import Logging
import SQLite

/// Append-only SQLite-backed log of every envelope flowing through a runtime.
/// RFC §6.4 (idempotency), §13.3 (subscription backfill), §19 (resume).
///
/// Idempotency: insertions use `INSERT OR IGNORE`. A second envelope with the
/// same `(session_id, message_id)` is silently ignored — the runtime can
/// safely call `append` for retransmits without risk of duplicate execution.
///
/// Replay: `replay(sessionId:after:)` returns an ordered `AsyncStream<Envelope>`
/// of envelopes for a session, optionally starting after a given message id,
/// using a monotonically-increasing `sequence` column for ordering.
public actor EventLog {
    private let db: Connection
    private let log: Logger
    private var nextSequence: Int64

    public init(path: String) throws {
        self.db = try Connection(path)
        self.log = Logger(label: "arcp.eventlog")
        try Self.applySchema(to: db)
        let maxSeq =
            (try? db.scalar("SELECT COALESCE(MAX(sequence), 0) FROM arcp_events") as? Int64) ?? 0
        self.nextSequence = maxSeq + 1
    }

    /// Open an in-memory event log (test-friendly). Each call is isolated.
    public static func inMemory() throws -> EventLog {
        try EventLog(path: ":memory:")
    }

    /// Append `envelope` to the log. Returns `false` if the message was already
    /// present (idempotency dedup), `true` if it was newly inserted.
    @discardableResult
    public func append(_ envelope: Envelope) throws -> Bool {
        guard let sessionId = envelope.sessionId else {
            throw ARCPError.invalidArgument(
                field: "session_id",
                detail: "Envelope must carry session_id to be persisted (RFC §6.1)."
            )
        }
        let json = try envelope.toJSON()
        guard let jsonString = String(data: json, encoding: .utf8) else {
            throw ARCPError.internal(detail: "envelope JSON not UTF-8", cause: nil)
        }
        let sequence = nextSequence
        let formatter = Self.timestampFormatter
        let timestamp = formatter.string(from: envelope.timestamp)
        let stmt = try db.prepare(
            """
            INSERT OR IGNORE INTO arcp_events
            (session_id, message_id, type_name, timestamp, job_id, stream_id,
             subscription_id, trace_id, span_id, correlation_id, causation_id,
             idempotency_key, priority, envelope_json, sequence)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        try stmt.run(
            sessionId.rawValue,
            envelope.id.rawValue,
            envelope.payload.typeName,
            timestamp,
            envelope.jobId?.rawValue,
            envelope.streamId?.rawValue,
            envelope.subscriptionId?.rawValue,
            envelope.traceId?.rawValue,
            envelope.spanId?.rawValue,
            envelope.correlationId?.rawValue,
            envelope.causationId?.rawValue,
            envelope.idempotencyKey?.rawValue,
            envelope.priority.rawValue,
            jsonString,
            sequence
        )
        if db.changes == 0 {
            log.debug(
                "duplicate ignored",
                metadata: ["session": "\(sessionId)", "msg": "\(envelope.id)"]
            )
            return false
        }
        nextSequence = sequence + 1
        return true
    }

    /// Replay every envelope for `sessionId`, optionally starting strictly after
    /// `after`'s sequence number. Order is by `sequence` ascending (RFC §13.3).
    public func replay(
        sessionId: SessionId,
        after: MessageId? = nil
    ) throws -> [Envelope] {
        let cutoffSequence: Int64
        if let after {
            cutoffSequence =
                try
                (db.scalar(
                    "SELECT sequence FROM arcp_events WHERE session_id = ? AND message_id = ?",
                    [sessionId.rawValue, after.rawValue]
                ) as? Int64) ?? -1
            if cutoffSequence == -1 {
                throw ARCPError.dataLoss(
                    detail: "after message_id \(after) not present in event log for session \(sessionId)"
                )
            }
        } else {
            cutoffSequence = 0
        }
        let rows = try db.prepare(
            """
            SELECT envelope_json FROM arcp_events
            WHERE session_id = ? AND sequence > ?
            ORDER BY sequence ASC
            """,
            [sessionId.rawValue, cutoffSequence]
        )
        let decoder = Envelope.makeDecoder()
        var output: [Envelope] = []
        for row in rows {
            guard let value = row[0] as? String,
                let data = value.data(using: .utf8)
            else { continue }
            output.append(try decoder.decode(Envelope.self, from: data))
        }
        return output
    }

    /// Total events stored for `sessionId` — useful for tests and diagnostics.
    public func count(for sessionId: SessionId) throws -> Int {
        let value =
            try db.scalar(
                "SELECT COUNT(*) FROM arcp_events WHERE session_id = ?",
                [sessionId.rawValue]
            ) as? Int64
        return Int(value ?? 0)
    }

    /// Lookup the persisted response for a logical idempotency key, if any.
    public func lookupIdempotency(
        principal: String,
        key: IdempotencyKey
    ) throws -> JSONValue? {
        guard
            let row = try db.scalar(
                "SELECT response_json FROM arcp_idempotency WHERE principal = ? AND idempotency_key = ?",
                [principal, key.rawValue]
            ) as? String
        else { return nil }
        guard let data = row.data(using: .utf8) else { return nil }
        return try Envelope.makeDecoder().decode(JSONValue.self, from: data)
    }

    /// Persist a logical idempotency response.
    public func recordIdempotency(
        principal: String,
        key: IdempotencyKey,
        response: JSONValue,
        expiresAt: Date
    ) throws {
        let json = try Envelope.makeEncoder().encode(response)
        guard let jsonString = String(data: json, encoding: .utf8) else { return }
        let expiresIso = Self.timestampFormatter.string(from: expiresAt)
        try db.run(
            """
            INSERT OR REPLACE INTO arcp_idempotency
            (principal, idempotency_key, response_json, expires_at)
            VALUES (?, ?, ?, ?)
            """,
            principal,
            key.rawValue,
            jsonString,
            expiresIso
        )
    }

    /// Persist an artifact body. RFC §16.2.
    @discardableResult
    public func putArtifact(
        sessionId: SessionId,
        artifactId: ArtifactId? = nil,
        mediaType: String,
        data: Data,
        ttlSeconds: Int? = nil
    ) throws -> ArtifactRef {
        let id = artifactId ?? .random()
        let sha = ArtifactStore.sha256(data)
        let expiresAt: Date? = ttlSeconds.map { Date(timeIntervalSinceNow: TimeInterval($0)) }
        let expiresIso = expiresAt.map { Self.timestampFormatter.string(from: $0) }
        try db.run(
            """
            INSERT OR REPLACE INTO arcp_artifacts
            (artifact_id, session_id, media_type, size, sha256, expires_at, body)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            id.rawValue,
            sessionId.rawValue,
            mediaType,
            Int64(data.count),
            sha,
            expiresIso,
            Blob(bytes: [UInt8](data))
        )
        return ArtifactRef(
            artifactId: id,
            uri: "arcp://session/\(sessionId.rawValue)/artifact/\(id.rawValue)",
            mediaType: mediaType,
            size: data.count,
            sha256: sha,
            expiresAt: expiresAt
        )
    }

    /// Fetch an artifact's bytes + reference. RFC §16.2.
    public func fetchArtifact(artifactId: ArtifactId) throws -> (ArtifactRef, Data) {
        let rows = try db.prepare(
            """
            SELECT artifact_id, session_id, media_type, size, sha256, expires_at, body
            FROM arcp_artifacts WHERE artifact_id = ?
            """,
            [artifactId.rawValue]
        )
        for row in rows {
            guard let id = row[0] as? String,
                let session = row[1] as? String,
                let mediaType = row[2] as? String,
                let size = row[3] as? Int64,
                let body = row[6] as? Blob
            else { continue }
            let sha = row[4] as? String
            let expiresAt = (row[5] as? String).flatMap(Self.timestampFormatter.date(from:))
            if let expiresAt, expiresAt < Date() {
                _ = try? db.run(
                    "DELETE FROM arcp_artifacts WHERE artifact_id = ?",
                    artifactId.rawValue
                )
                throw ARCPError.notFound(kind: "artifact", id: id)
            }
            let ref = ArtifactRef(
                artifactId: ArtifactId(id),
                uri: "arcp://session/\(session)/artifact/\(id)",
                mediaType: mediaType,
                size: Int(size),
                sha256: sha,
                expiresAt: expiresAt
            )
            return (ref, Data(body.bytes))
        }
        throw ARCPError.notFound(kind: "artifact", id: artifactId.rawValue)
    }

    /// Release (delete) an artifact.
    public func releaseArtifact(artifactId: ArtifactId) throws {
        try db.run("DELETE FROM arcp_artifacts WHERE artifact_id = ?", artifactId.rawValue)
    }

    /// Sweep expired artifacts. Called by `ArtifactStore`'s periodic Task.
    public func sweepExpiredArtifacts() {
        let now = Self.timestampFormatter.string(from: Date())
        _ = try? db.run(
            "DELETE FROM arcp_artifacts WHERE expires_at IS NOT NULL AND expires_at < ?",
            now
        )
    }

    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func applySchema(to db: Connection) throws {
        guard let url = Bundle.module.url(forResource: "schema", withExtension: "sql"),
            let data = try? Data(contentsOf: url),
            let sql = String(data: data, encoding: .utf8)
        else {
            throw ARCPError.internal(
                detail: "schema.sql resource missing from ARCP bundle",
                cause: nil
            )
        }
        try db.execute(sql)
    }
}
