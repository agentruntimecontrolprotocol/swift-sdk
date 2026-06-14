/// Canonical ARCP error taxonomy. ARCP v1.1 §12.
///
/// Wire form is the uppercase string from the §12 table. A handful of
/// legacy/gRPC-style strings are accepted on decode as aliases for the
/// canonical §12 codes (`INVALID_ARGUMENT` → `INVALID_REQUEST`, `INTERNAL`
/// → `INTERNAL_ERROR`, `RATE_LIMITED` → `RESOURCE_EXHAUSTED`); encoding
/// always uses the canonical §12 wire string.
public enum ErrorCode: String, Sendable, Hashable, Codable, CaseIterable {
    case ok = "OK"
    case cancelled = "CANCELLED"
    case unknown = "UNKNOWN"
    /// `INVALID_REQUEST` — malformed envelope or schema violation (§12).
    case invalidArgument = "INVALID_REQUEST"
    case deadlineExceeded = "DEADLINE_EXCEEDED"
    /// `TIMEOUT` — job exceeded `max_runtime_sec` (§12; §7.3).
    case timeout = "TIMEOUT"
    case notFound = "NOT_FOUND"
    /// `JOB_NOT_FOUND` — referenced `job_id` does not exist or is not
    /// visible to the caller (§12; §7.4).
    case jobNotFound = "JOB_NOT_FOUND"
    /// `DUPLICATE_KEY` — `idempotency_key` reuse with conflicting
    /// parameters (§12; §7.2).
    case duplicateKey = "DUPLICATE_KEY"
    case alreadyExists = "ALREADY_EXISTS"
    case permissionDenied = "PERMISSION_DENIED"
    case resourceExhausted = "RESOURCE_EXHAUSTED"
    case failedPrecondition = "FAILED_PRECONDITION"
    case aborted = "ABORTED"
    case outOfRange = "OUT_OF_RANGE"
    case unimplemented = "UNIMPLEMENTED"
    /// `INTERNAL_ERROR` — unrecoverable runtime fault (§12).
    case `internal` = "INTERNAL_ERROR"
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
    /// `AGENT_NOT_AVAILABLE` — the requested `agent` is not registered
    /// (§12; §7.5).
    case agentNotAvailable = "AGENT_NOT_AVAILABLE"
    /// `AGENT_VERSION_NOT_AVAILABLE` — `job.submit` named an
    /// `agent@version` the runtime does not have (ARCP v1.1 §12; §7.5).
    case agentVersionNotAvailable = "AGENT_VERSION_NOT_AVAILABLE"
    /// `RESUME_WINDOW_EXPIRED` — resume attempted after the buffered
    /// event window closed (§12; §6.3).
    case resumeWindowExpired = "RESUME_WINDOW_EXPIRED"

    /// True if a typical client should retry. ARCP v1.1 §12.
    ///
    /// `INTERNAL_ERROR` is always retryable. `LEASE_EXPIRED` and
    /// `BUDGET_EXHAUSTED` are explicitly NOT retryable.
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
        // Legacy/gRPC-style aliases accepted on decode for backward
        // compatibility with peers that predate the §12 wire strings.
        switch raw {
        case "RATE_LIMITED":
            self = .resourceExhausted
            return
        case "INVALID_ARGUMENT":
            self = .invalidArgument
            return
        case "INTERNAL":
            self = .internal
            return
        default:
            break
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
