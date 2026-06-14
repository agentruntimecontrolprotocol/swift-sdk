import Foundation

/// Discriminated union of every ARCP message variant the SDK understands. The
/// enum name (`MessageType`) mirrors the RFC §6.2 grouping, and each case
/// carries a strongly-typed payload struct from `Messages/`.
///
/// The wire `type` string is computed via `typeName` and recovered via
/// `decodePayload(typeName:from:)`. The custom `Codable` on `Envelope` reads
/// `type`, then dispatches to this static decoder so the payload can be parsed
/// against its specific schema.
public enum MessageType: Sendable, Hashable {
    // Session (RFC §8)
    case sessionOpen(SessionOpenPayload)
    case sessionChallenge(SessionChallengePayload)
    case sessionAuthenticate(SessionAuthenticatePayload)
    case sessionAccepted(SessionAcceptedPayload)
    case sessionUnauthenticated(SessionUnauthenticatedPayload)
    case sessionRejected(SessionRejectedPayload)
    case sessionRefresh(SessionRefreshPayload)
    case sessionEvicted(SessionEvictedPayload)
    case sessionClose(SessionClosePayload)
    case sessionListJobs(SessionListJobsPayload)
    case sessionJobs(SessionJobsPayload)

    // Control (RFC §6.2 / §10.4 / §10.5 / §11.2 / §19)
    case ping(PingPayload)
    case pong(PongPayload)
    case ack(AckPayload)
    case nack(NackPayload)
    case cancel(CancelPayload)
    case cancelAccepted(CancelAcceptedPayload)
    case cancelRefused(CancelRefusedPayload)
    case interrupt(InterruptPayload)
    case resume(ResumePayload)
    case backpressure(BackpressurePayload)

    // Execution (ARCP v1.1 §7 / §8)
    case toolInvoke(ToolInvokePayload)
    case toolResult(ToolResultPayload)
    case toolError(ToolErrorPayload)
    case jobAccepted(JobAcceptedPayload)
    case jobStarted(JobStartedPayload)
    case jobProgress(JobProgressPayload)
    case jobHeartbeat(JobHeartbeatPayload)
    case jobCompleted(JobCompletedPayload)
    case jobFailed(JobFailedPayload)
    case jobCancelled(JobCancelledPayload)
    case jobResultChunk(JobResultChunkPayload)
    case jobStatus(JobStatusPayload)

    // Streaming (ARCP v1.1 §8.4)
    case streamOpen(StreamOpenPayload)
    case streamChunk(StreamChunkPayload)
    case streamClose(StreamClosePayload)
    case streamError(StreamErrorPayload)

    // Permissions & Leases (ARCP v1.1 §9 / §15.4)
    case permissionRequest(PermissionRequestPayload)
    case permissionGrant(PermissionGrantPayload)
    case permissionDeny(PermissionDenyPayload)
    case leaseGranted(LeaseGrantedPayload)
    case leaseExtended(LeaseExtendedPayload)
    case leaseRevoked(LeaseRevokedPayload)
    case leaseRefresh(LeaseRefreshPayload)

    // Subscriptions (ARCP v1.1 §7.6)
    case subscribe(SubscribePayload)
    case subscribeAccepted(SubscribeAcceptedPayload)
    case subscribeEvent(SubscribeEventPayload)
    case unsubscribe(UnsubscribePayload)
    case subscribeClosed(SubscribeClosedPayload)

    // Artifacts (ARCP v1.1 §8.2 artifact_ref)
    case artifactPut(ArtifactPutPayload)
    case artifactFetch(ArtifactFetchPayload)
    case artifactRef(ArtifactRefPayload)
    case artifactRelease(ArtifactReleasePayload)

    // Telemetry (ARCP v1.1 §8.2 / §11)
    case eventEmit(EventEmitPayload)
    case log(LogPayload)
    case metric(MetricPayload)
    case traceSpan(TraceSpanPayload)

    /// Decoded but not understood (extension or out-of-scope core type). The
    /// payload is preserved verbatim as a `JSONValue` so callers can decide
    /// whether to drop, nack, or hand off via the `ExtensionRegistry`.
    case unknown(typeName: String, payload: JSONValue)
}

extension MessageType {
    /// Wire `type` string for this case. RFC §6.2.
    public var typeName: String {
        switch self {
        case .sessionOpen: return "session.open"
        case .sessionChallenge: return "session.challenge"
        case .sessionAuthenticate: return "session.authenticate"
        case .sessionAccepted: return "session.accepted"
        case .sessionUnauthenticated: return "session.unauthenticated"
        case .sessionRejected: return "session.rejected"
        case .sessionRefresh: return "session.refresh"
        case .sessionEvicted: return "session.evicted"
        case .sessionClose: return "session.close"
        case .sessionListJobs: return "session.list_jobs"
        case .sessionJobs: return "session.jobs"
        case .ping: return "ping"
        case .pong: return "pong"
        case .ack: return "ack"
        case .nack: return "nack"
        case .cancel: return "cancel"
        case .cancelAccepted: return "cancel.accepted"
        case .cancelRefused: return "cancel.refused"
        case .interrupt: return "interrupt"
        case .resume: return "resume"
        case .backpressure: return "backpressure"
        case .toolInvoke: return "tool.invoke"
        case .toolResult: return "tool.result"
        case .toolError: return "tool.error"
        case .jobAccepted: return "job.accepted"
        case .jobStarted: return "job.started"
        case .jobProgress: return "job.progress"
        case .jobHeartbeat: return "job.heartbeat"
        case .jobCompleted: return "job.completed"
        case .jobFailed: return "job.failed"
        case .jobCancelled: return "job.cancelled"
        case .jobResultChunk: return "job.result_chunk"
        case .jobStatus: return "job.status"
        case .streamOpen: return "stream.open"
        case .streamChunk: return "stream.chunk"
        case .streamClose: return "stream.close"
        case .streamError: return "stream.error"
        case .permissionRequest: return "permission.request"
        case .permissionGrant: return "permission.grant"
        case .permissionDeny: return "permission.deny"
        case .leaseGranted: return "lease.granted"
        case .leaseExtended: return "lease.extended"
        case .leaseRevoked: return "lease.revoked"
        case .leaseRefresh: return "lease.refresh"
        case .subscribe: return "subscribe"
        case .subscribeAccepted: return "subscribe.accepted"
        case .subscribeEvent: return "subscribe.event"
        case .unsubscribe: return "unsubscribe"
        case .subscribeClosed: return "subscribe.closed"
        case .artifactPut: return "artifact.put"
        case .artifactFetch: return "artifact.fetch"
        case .artifactRef: return "artifact.ref"
        case .artifactRelease: return "artifact.release"
        case .eventEmit: return "event.emit"
        case .log: return "log"
        case .metric: return "metric"
        case .traceSpan: return "trace.span"
        case .unknown(let typeName, _): return typeName
        }
    }

    /// Encode the case's payload to `encoder`. Used by `Envelope.encode(to:)`.
    public func encodePayload(to encoder: any Encoder) throws {
        switch self {
        case .sessionOpen(let value): try value.encode(to: encoder)
        case .sessionChallenge(let value): try value.encode(to: encoder)
        case .sessionAuthenticate(let value): try value.encode(to: encoder)
        case .sessionAccepted(let value): try value.encode(to: encoder)
        case .sessionUnauthenticated(let value): try value.encode(to: encoder)
        case .sessionRejected(let value): try value.encode(to: encoder)
        case .sessionRefresh(let value): try value.encode(to: encoder)
        case .sessionEvicted(let value): try value.encode(to: encoder)
        case .sessionClose(let value): try value.encode(to: encoder)
        case .sessionListJobs(let value): try value.encode(to: encoder)
        case .sessionJobs(let value): try value.encode(to: encoder)
        case .ping(let value): try value.encode(to: encoder)
        case .pong(let value): try value.encode(to: encoder)
        case .ack(let value): try value.encode(to: encoder)
        case .nack(let value): try value.encode(to: encoder)
        case .cancel(let value): try value.encode(to: encoder)
        case .cancelAccepted(let value): try value.encode(to: encoder)
        case .cancelRefused(let value): try value.encode(to: encoder)
        case .interrupt(let value): try value.encode(to: encoder)
        case .resume(let value): try value.encode(to: encoder)
        case .backpressure(let value): try value.encode(to: encoder)
        case .toolInvoke(let value): try value.encode(to: encoder)
        case .toolResult(let value): try value.encode(to: encoder)
        case .toolError(let value): try value.encode(to: encoder)
        case .jobAccepted(let value): try value.encode(to: encoder)
        case .jobStarted(let value): try value.encode(to: encoder)
        case .jobProgress(let value): try value.encode(to: encoder)
        case .jobHeartbeat(let value): try value.encode(to: encoder)
        case .jobCompleted(let value): try value.encode(to: encoder)
        case .jobFailed(let value): try value.encode(to: encoder)
        case .jobCancelled(let value): try value.encode(to: encoder)
        case .jobResultChunk(let value): try value.encode(to: encoder)
        case .jobStatus(let value): try value.encode(to: encoder)
        case .streamOpen(let value): try value.encode(to: encoder)
        case .streamChunk(let value): try value.encode(to: encoder)
        case .streamClose(let value): try value.encode(to: encoder)
        case .streamError(let value): try value.encode(to: encoder)
        case .permissionRequest(let value): try value.encode(to: encoder)
        case .permissionGrant(let value): try value.encode(to: encoder)
        case .permissionDeny(let value): try value.encode(to: encoder)
        case .leaseGranted(let value): try value.encode(to: encoder)
        case .leaseExtended(let value): try value.encode(to: encoder)
        case .leaseRevoked(let value): try value.encode(to: encoder)
        case .leaseRefresh(let value): try value.encode(to: encoder)
        case .subscribe(let value): try value.encode(to: encoder)
        case .subscribeAccepted(let value): try value.encode(to: encoder)
        case .subscribeEvent(let value): try value.encode(to: encoder)
        case .unsubscribe(let value): try value.encode(to: encoder)
        case .subscribeClosed(let value): try value.encode(to: encoder)
        case .artifactPut(let value): try value.encode(to: encoder)
        case .artifactFetch(let value): try value.encode(to: encoder)
        case .artifactRef(let value): try value.encode(to: encoder)
        case .artifactRelease(let value): try value.encode(to: encoder)
        case .eventEmit(let value): try value.encode(to: encoder)
        case .log(let value): try value.encode(to: encoder)
        case .metric(let value): try value.encode(to: encoder)
        case .traceSpan(let value): try value.encode(to: encoder)
        case .unknown(_, let payload): try payload.encode(to: encoder)
        }
    }

    /// Static decoder dispatch keyed on the wire `type` string.
    public static func decodePayload(typeName: String, from decoder: any Decoder) throws -> MessageType {
        switch typeName {
        case "session.open":
            return .sessionOpen(try SessionOpenPayload(from: decoder))
        case "session.challenge":
            return .sessionChallenge(try SessionChallengePayload(from: decoder))
        case "session.authenticate":
            return .sessionAuthenticate(try SessionAuthenticatePayload(from: decoder))
        case "session.accepted":
            return .sessionAccepted(try SessionAcceptedPayload(from: decoder))
        case "session.unauthenticated":
            return .sessionUnauthenticated(try SessionUnauthenticatedPayload(from: decoder))
        case "session.rejected":
            return .sessionRejected(try SessionRejectedPayload(from: decoder))
        case "session.refresh":
            return .sessionRefresh(try SessionRefreshPayload(from: decoder))
        case "session.evicted":
            return .sessionEvicted(try SessionEvictedPayload(from: decoder))
        case "session.close":
            return .sessionClose(try SessionClosePayload(from: decoder))
        case "session.list_jobs":
            return .sessionListJobs(try SessionListJobsPayload(from: decoder))
        case "session.jobs":
            return .sessionJobs(try SessionJobsPayload(from: decoder))
        case "ping":
            return .ping(try PingPayload(from: decoder))
        case "pong":
            return .pong(try PongPayload(from: decoder))
        case "ack":
            return .ack(try AckPayload(from: decoder))
        case "nack":
            return .nack(try NackPayload(from: decoder))
        case "cancel":
            return .cancel(try CancelPayload(from: decoder))
        case "cancel.accepted":
            return .cancelAccepted(try CancelAcceptedPayload(from: decoder))
        case "cancel.refused":
            return .cancelRefused(try CancelRefusedPayload(from: decoder))
        case "interrupt":
            return .interrupt(try InterruptPayload(from: decoder))
        case "resume":
            return .resume(try ResumePayload(from: decoder))
        case "backpressure":
            return .backpressure(try BackpressurePayload(from: decoder))
        case "tool.invoke":
            return .toolInvoke(try ToolInvokePayload(from: decoder))
        case "tool.result":
            return .toolResult(try ToolResultPayload(from: decoder))
        case "tool.error":
            return .toolError(try ToolErrorPayload(from: decoder))
        case "job.accepted":
            return .jobAccepted(try JobAcceptedPayload(from: decoder))
        case "job.started":
            return .jobStarted(try JobStartedPayload(from: decoder))
        case "job.progress":
            return .jobProgress(try JobProgressPayload(from: decoder))
        case "job.heartbeat":
            return .jobHeartbeat(try JobHeartbeatPayload(from: decoder))
        case "job.completed":
            return .jobCompleted(try JobCompletedPayload(from: decoder))
        case "job.failed":
            return .jobFailed(try JobFailedPayload(from: decoder))
        case "job.cancelled":
            return .jobCancelled(try JobCancelledPayload(from: decoder))
        case "job.result_chunk":
            return .jobResultChunk(try JobResultChunkPayload(from: decoder))
        case "job.status":
            return .jobStatus(try JobStatusPayload(from: decoder))
        case "stream.open":
            return .streamOpen(try StreamOpenPayload(from: decoder))
        case "stream.chunk":
            return .streamChunk(try StreamChunkPayload(from: decoder))
        case "stream.close":
            return .streamClose(try StreamClosePayload(from: decoder))
        case "stream.error":
            return .streamError(try StreamErrorPayload(from: decoder))
        case "permission.request":
            return .permissionRequest(try PermissionRequestPayload(from: decoder))
        case "permission.grant":
            return .permissionGrant(try PermissionGrantPayload(from: decoder))
        case "permission.deny":
            return .permissionDeny(try PermissionDenyPayload(from: decoder))
        case "lease.granted":
            return .leaseGranted(try LeaseGrantedPayload(from: decoder))
        case "lease.extended":
            return .leaseExtended(try LeaseExtendedPayload(from: decoder))
        case "lease.revoked":
            return .leaseRevoked(try LeaseRevokedPayload(from: decoder))
        case "lease.refresh":
            return .leaseRefresh(try LeaseRefreshPayload(from: decoder))
        case "subscribe":
            return .subscribe(try SubscribePayload(from: decoder))
        case "subscribe.accepted":
            return .subscribeAccepted(try SubscribeAcceptedPayload(from: decoder))
        case "subscribe.event":
            return .subscribeEvent(try SubscribeEventPayload(from: decoder))
        case "unsubscribe":
            return .unsubscribe(try UnsubscribePayload(from: decoder))
        case "subscribe.closed":
            return .subscribeClosed(try SubscribeClosedPayload(from: decoder))
        case "artifact.put":
            return .artifactPut(try ArtifactPutPayload(from: decoder))
        case "artifact.fetch":
            return .artifactFetch(try ArtifactFetchPayload(from: decoder))
        case "artifact.ref":
            return .artifactRef(try ArtifactRefPayload(from: decoder))
        case "artifact.release":
            return .artifactRelease(try ArtifactReleasePayload(from: decoder))
        case "event.emit":
            return .eventEmit(try EventEmitPayload(from: decoder))
        case "log":
            return .log(try LogPayload(from: decoder))
        case "metric":
            return .metric(try MetricPayload(from: decoder))
        case "trace.span":
            return .traceSpan(try TraceSpanPayload(from: decoder))
        default:
            return .unknown(typeName: typeName, payload: try JSONValue(from: decoder))
        }
    }
}
