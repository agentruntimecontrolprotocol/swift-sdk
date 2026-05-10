import CryptoKit
import Foundation
import Logging

/// Per-runtime artifact store. RFC §16.
///
/// Storage delegates to `EventLog`'s shared SQLite connection (so the runtime
/// has a single durable file). This actor owns the periodic retention sweep
/// (RFC §16.3).
public actor ArtifactStore {
    private let log: Logger
    private let eventLog: EventLog
    private var sweepTask: Task<Void, Never>?

    public init(eventLog: EventLog) {
        self.eventLog = eventLog
        self.log = Logger(label: "arcp.artifacts")
    }

    @discardableResult
    public func put(
        sessionId: SessionId,
        artifactId: ArtifactId? = nil,
        mediaType: String,
        data: Data,
        ttlSeconds: Int? = nil
    ) async throws -> ArtifactRef {
        try await eventLog.putArtifact(
            sessionId: sessionId,
            artifactId: artifactId,
            mediaType: mediaType,
            data: data,
            ttlSeconds: ttlSeconds
        )
    }

    public func fetch(artifactId: ArtifactId) async throws -> (ArtifactRef, Data) {
        try await eventLog.fetchArtifact(artifactId: artifactId)
    }

    public func release(artifactId: ArtifactId) async throws {
        try await eventLog.releaseArtifact(artifactId: artifactId)
    }

    public func startSweep(interval: TimeInterval = 60) {
        sweepTask?.cancel()
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch { return }
                await self?.sweep()
            }
        }
    }

    public func stopSweep() {
        sweepTask?.cancel()
    }

    private func sweep() async {
        await eventLog.sweepExpiredArtifacts()
    }

    /// Hex-encoded SHA-256 of `data`. Exposed for `EventLog.putArtifact`.
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
