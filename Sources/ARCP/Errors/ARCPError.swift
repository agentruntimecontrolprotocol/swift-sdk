import Foundation

/// All errors raised by the SDK. RFC §18.
///
/// Public APIs throw `ARCPError`. Downstream library errors are wrapped at the
/// boundary into `.internal(cause:)` or a more specific case. The `code` and
/// `isRetryable` computed properties provide RFC-aligned views suitable for
/// error envelopes (`tool.error`, `job.failed`, `nack`).
public enum ARCPError: Error, Sendable {
    /// Operation was cancelled by caller, runtime, or policy.
    case cancelled(operation: String, reason: String)

    /// Caller passed a malformed or invalid argument.
    case invalidArgument(field: String, detail: String)

    /// Operation timed out.
    case deadlineExceeded(operation: String)

    /// Referenced entity does not exist.
    case notFound(kind: String, id: String)

    /// Entity creation conflicted.
    case alreadyExists(kind: String, id: String)

    /// Caller lacks the required permission or active lease.
    case permissionDenied(permission: String, resource: String)

    /// Quota or rate limit hit. Retry-after honored when present.
    case resourceExhausted(reason: String, retryAfter: Duration?)

    /// Pre-condition unmet (e.g. job not in cancellable state).
    case failedPrecondition(detail: String)

    /// Hard termination or concurrency conflict.
    case aborted(reason: String)

    /// Argument outside of valid range.
    case outOfRange(field: String, detail: String)

    /// Feature not supported by this runtime.
    case unimplemented(section: String, detail: String)

    /// Internal runtime error wrapping a downstream cause.
    case `internal`(detail: String, cause: (any Error)?)

    /// Transient unavailability.
    case unavailable(reason: String, retryAfter: Duration?)

    /// Unrecoverable data loss (e.g. retention expired before resume).
    case dataLoss(detail: String)

    /// Missing or invalid credentials.
    case unauthenticated(detail: String)

    /// Heartbeats missed beyond threshold (RFC §10.3).
    case heartbeatLost(jobId: JobId, missed: Int)

    /// Operation attempted with an expired lease (RFC §15.5).
    case leaseExpired(leaseId: LeaseId, expiredAt: Date)

    /// Operation attempted with a revoked lease.
    case leaseRevoked(leaseId: LeaseId, reason: String)

    /// Stream or subscription dropped due to overflow (RFC §11.2 / §13.4).
    case backpressureOverflow(streamOrSubscription: String, dropped: Int)

    /// A `cost.budget` capability counter reached its maximum
    /// (ARCP v1.1 §12; §9.6).
    case budgetExhausted(detail: String)

    /// `job.submit` named an `agent@version` the runtime does not have
    /// (ARCP v1.1 §12; §7.5).
    case agentVersionNotAvailable(agent: String, version: String)

    /// Catch-all unknown error; avoid in favor of a specific case.
    case unknown(message: String)
}

extension ARCPError {
    /// Canonical RFC §18.2 code.
    public var code: ErrorCode {
        switch self {
        case .cancelled: return .cancelled
        case .invalidArgument, .outOfRange: return .invalidArgument
        case .deadlineExceeded: return .deadlineExceeded
        case .notFound: return .notFound
        case .alreadyExists: return .alreadyExists
        case .permissionDenied: return .permissionDenied
        case .resourceExhausted: return .resourceExhausted
        case .failedPrecondition: return .failedPrecondition
        case .aborted: return .aborted
        case .unimplemented: return .unimplemented
        case .internal: return .internal
        case .unavailable: return .unavailable
        case .dataLoss: return .dataLoss
        case .unauthenticated: return .unauthenticated
        case .heartbeatLost: return .heartbeatLost
        case .leaseExpired: return .leaseExpired
        case .leaseRevoked: return .leaseRevoked
        case .backpressureOverflow: return .backpressureOverflow
        case .budgetExhausted: return .budgetExhausted
        case .agentVersionNotAvailable: return .agentVersionNotAvailable
        case .unknown: return .unknown
        }
    }

    /// True if a typical caller should retry. Combines the case-specific
    /// signal with the §18.3 default for the underlying code.
    public var isRetryable: Bool {
        switch self {
        case .resourceExhausted, .unavailable: return true
        case .deadlineExceeded: return true
        case .aborted: return true
        case .internal: return true
        default: return false
        }
    }

    /// One-line message suitable for the wire `message` field of an error envelope.
    public var message: String {
        switch self {
        case .cancelled(let op, let reason):
            return "Cancelled \(op): \(reason)"
        case .invalidArgument(let field, let detail):
            return "Invalid argument \(field): \(detail)"
        case .deadlineExceeded(let op):
            return "Deadline exceeded for \(op)"
        case .notFound(let kind, let id):
            return "\(kind) \(id) not found"
        case .alreadyExists(let kind, let id):
            return "\(kind) \(id) already exists"
        case .permissionDenied(let permission, let resource):
            return "Permission \(permission) denied on \(resource)"
        case .resourceExhausted(let reason, _):
            return "Resource exhausted: \(reason)"
        case .failedPrecondition(let detail):
            return "Failed precondition: \(detail)"
        case .aborted(let reason):
            return "Aborted: \(reason)"
        case .outOfRange(let field, let detail):
            return "Out of range \(field): \(detail)"
        case .unimplemented(let section, let detail):
            return "Unimplemented (RFC \(section)): \(detail)"
        case .internal(let detail, _):
            return "Internal: \(detail)"
        case .unavailable(let reason, _):
            return "Unavailable: \(reason)"
        case .dataLoss(let detail):
            return "Data loss: \(detail)"
        case .unauthenticated(let detail):
            return "Unauthenticated: \(detail)"
        case .heartbeatLost(let jobId, let missed):
            return "Heartbeat lost on \(jobId) (missed \(missed))"
        case .leaseExpired(let leaseId, let at):
            return "Lease \(leaseId) expired at \(at)"
        case .leaseRevoked(let leaseId, let reason):
            return "Lease \(leaseId) revoked: \(reason)"
        case .backpressureOverflow(let target, let dropped):
            return "Backpressure overflow on \(target); dropped \(dropped)"
        case .budgetExhausted(let detail):
            return "Budget exhausted: \(detail)"
        case .agentVersionNotAvailable(let agent, let version):
            return "Agent version not available: \(agent)@\(version)"
        case .unknown(let message):
            return message
        }
    }

    /// Optional structured details for the wire `details` map.
    public var details: [String: JSONValue] {
        switch self {
        case .resourceExhausted(_, let retryAfter), .unavailable(_, let retryAfter):
            if let retryAfter {
                let seconds =
                    Double(retryAfter.components.seconds)
                    + Double(retryAfter.components.attoseconds) / 1.0e18
                return ["retry_after_seconds": .double(seconds)]
            }
            return [:]
        case .heartbeatLost(let jobId, let missed):
            return ["job_id": .string(jobId.rawValue), "missed": .int(Int64(missed))]
        case .leaseExpired(let leaseId, let at):
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return [
                "lease_id": .string(leaseId.rawValue),
                "expired_at": .string(formatter.string(from: at)),
            ]
        case .leaseRevoked(let leaseId, let reason):
            return ["lease_id": .string(leaseId.rawValue), "reason": .string(reason)]
        case .backpressureOverflow(let target, let dropped):
            return ["target": .string(target), "dropped": .int(Int64(dropped))]
        case .agentVersionNotAvailable(let agent, let version):
            return ["agent": .string(agent), "version": .string(version)]
        case .invalidArgument(let field, _), .outOfRange(let field, _):
            return ["field": .string(field)]
        case .notFound(let kind, let id), .alreadyExists(let kind, let id):
            return ["kind": .string(kind), "id": .string(id)]
        case .unimplemented(let section, _):
            return ["section": .string(section)]
        default:
            return [:]
        }
    }
}

extension ARCPError: CustomStringConvertible {
    public var description: String { "[\(code.rawValue)] \(message)" }
}
