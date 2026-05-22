/// Canonical ARCP error taxonomy. RFC §18.2.
///
/// Wire form is the uppercase string. `RATE_LIMITED` is accepted on decode as
/// an alias for `RESOURCE_EXHAUSTED` (RFC §18.2 footnote); encoding always
/// uses the canonical `RESOURCE_EXHAUSTED`.
public enum ErrorCode: String, Sendable, Hashable, Codable, CaseIterable {
    case ok = "OK"
    case cancelled = "CANCELLED"
    case unknown = "UNKNOWN"
    case invalidArgument = "INVALID_ARGUMENT"
    case deadlineExceeded = "DEADLINE_EXCEEDED"
    case notFound = "NOT_FOUND"
    case alreadyExists = "ALREADY_EXISTS"
    case permissionDenied = "PERMISSION_DENIED"
    case resourceExhausted = "RESOURCE_EXHAUSTED"
    case failedPrecondition = "FAILED_PRECONDITION"
    case aborted = "ABORTED"
    case outOfRange = "OUT_OF_RANGE"
    case unimplemented = "UNIMPLEMENTED"
    case `internal` = "INTERNAL"
    case unavailable = "UNAVAILABLE"
    case dataLoss = "DATA_LOSS"
    case unauthenticated = "UNAUTHENTICATED"
    case heartbeatLost = "HEARTBEAT_LOST"
    case leaseExpired = "LEASE_EXPIRED"
    case leaseRevoked = "LEASE_REVOKED"
    case leaseSubsetViolation = "LEASE_SUBSET_VIOLATION"
    case backpressureOverflow = "BACKPRESSURE_OVERFLOW"
    /// `BUDGET_EXHAUSTED` — a `cost.budget` counter reached its maximum
    /// (ARCP v1.1 §12; §9.6).
    case budgetExhausted = "BUDGET_EXHAUSTED"
    /// `AGENT_VERSION_NOT_AVAILABLE` — `job.submit` named an
    /// `agent@version` the runtime does not have (ARCP v1.1 §12; §7.5).
    case agentVersionNotAvailable = "AGENT_VERSION_NOT_AVAILABLE"

    /// True if a typical client should retry. RFC §18.3.
    public var isRetryableByDefault: Bool {
        switch self {
        case .resourceExhausted, .unavailable, .deadlineExceeded, .internal, .aborted:
            return true
        default:
            return false
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if raw == "RATE_LIMITED" {
            self = .resourceExhausted
            return
        }
        if let value = ErrorCode(rawValue: raw) {
            self = value
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unknown ARCP error code \(raw)"
        )
    }
}
