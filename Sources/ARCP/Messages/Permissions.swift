import Foundation

/// One entry in a `cost.budget` capability list (ARCP v1.1 §9.6).
///
/// On the wire this is an amount string like `"USD:5.00"` or
/// `"credits:1000"`. `currency` is a free-form identifier (`USD`,
/// `EUR`, `credits`, or runtime-defined) and `amount` is a
/// non-negative finite decimal.
public struct CostBudgetAmount: Sendable, Hashable, Codable {
    public var currency: String
    public var amount: Double

    public init(currency: String, amount: Double) {
        self.currency = currency
        self.amount = amount
    }

    /// Errors from ``CostBudgetAmount/parse(_:)``.
    public enum ParseError: Error, Sendable, Equatable {
        case missingSeparator(String)
        case emptyCurrency(String)
        case invalidAmount(String)
        case negative(String)
    }

    /// Parse an amount string per §9.6 (`currency ":" decimal`).
    public static func parse(_ input: String) throws -> CostBudgetAmount {
        guard let colon = input.firstIndex(of: ":") else {
            throw ParseError.missingSeparator(input)
        }
        let currency = String(input[..<colon])
        let rest = String(input[input.index(after: colon)...])
        if currency.isEmpty {
            throw ParseError.emptyCurrency(input)
        }
        guard let value = Double(rest), value.isFinite else {
            throw ParseError.invalidAmount(input)
        }
        if value < 0 {
            throw ParseError.negative(input)
        }
        return CostBudgetAmount(currency: currency, amount: value)
    }

    /// Wire form, e.g. `"USD:5.0"`.
    public var wire: String {
        // Format like Rust: integer when possible, otherwise plain decimal.
        if amount.rounded() == amount, abs(amount) < 1e15 {
            return "\(currency):\(Int64(amount))"
        }
        return "\(currency):\(amount)"
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = try CostBudgetAmount.parse(raw)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wire)
    }
}

/// `cost.budget` lease capability (ARCP v1.1 §9.6).
///
/// Wire shape: an array of amount strings, one per currency, e.g.
/// `["USD:5.00", "credits:1000"]`. Multiple currencies are tracked
/// independently. This type carries only the declared upper bounds;
/// the runtime tracks remaining counters separately (see
/// ``BudgetTracker``).
public struct CostBudget: Sendable, Hashable, Codable {
    public var amounts: [CostBudgetAmount]

    public init(amounts: [CostBudgetAmount] = []) {
        self.amounts = amounts
    }

    public var isEmpty: Bool { amounts.isEmpty }

    /// Declared maximum for `currency`, if any.
    public func max(for currency: String) -> Double? {
        amounts.first(where: { $0.currency == currency })?.amount
    }

    /// Subset check (ARCP v1.1 §9.4). `remaining` supplies per-currency
    /// remaining values (`max - consumed`); a currency absent from
    /// `remaining` is treated as fully unspent.
    ///
    /// Returns the first currency in `child` that exceeds the remaining
    /// envelope, or `nil` when `child` is a valid subset.
    public func subsetViolation(
        of child: CostBudget,
        remaining: [String: Double] = [:]
    ) -> String? {
        for c in child.amounts {
            let parentRemaining: Double?
            if let r = remaining[c.currency] {
                parentRemaining = r
            } else {
                parentRemaining = max(for: c.currency)
            }
            guard let limit = parentRemaining else {
                // Currency not present on parent at all.
                return c.currency
            }
            if c.amount > limit {
                return c.currency
            }
        }
        return nil
    }

    public init(from decoder: any Decoder) throws {
        // Transparent wire form: array of amount strings.
        let c = try decoder.singleValueContainer()
        let raws = try c.decode([String].self)
        self.amounts = try raws.map(CostBudgetAmount.parse)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(amounts.map { $0.wire })
    }
}

/// `permission.request` payload. RFC §15.4.
public struct PermissionRequestPayload: Sendable, Codable, Hashable {
    public var permission: String
    public var resource: String
    public var operation: String
    public var reason: String?
    public var requestedLeaseSeconds: Int

    public init(
        permission: String,
        resource: String,
        operation: String,
        reason: String? = nil,
        requestedLeaseSeconds: Int = 60
    ) {
        self.permission = permission
        self.resource = resource
        self.operation = operation
        self.reason = reason
        self.requestedLeaseSeconds = requestedLeaseSeconds
    }

    enum CodingKeys: String, CodingKey {
        case permission, resource, operation, reason
        case requestedLeaseSeconds = "requested_lease_seconds"
    }
}

/// `permission.grant` payload. RFC §15.4.
public struct PermissionGrantPayload: Sendable, Codable, Hashable {
    public var permission: String
    public var resource: String
    public var operation: String
    public var leaseSeconds: Int

    public init(permission: String, resource: String, operation: String, leaseSeconds: Int) {
        self.permission = permission
        self.resource = resource
        self.operation = operation
        self.leaseSeconds = leaseSeconds
    }

    enum CodingKeys: String, CodingKey {
        case permission, resource, operation
        case leaseSeconds = "lease_seconds"
    }
}

/// `permission.deny` payload. RFC §15.4.
public struct PermissionDenyPayload: Sendable, Codable, Hashable {
    public var permission: String
    public var resource: String
    public var reason: String

    public init(permission: String, resource: String, reason: String) {
        self.permission = permission
        self.resource = resource
        self.reason = reason
    }
}

/// `lease.granted` payload. RFC §15.5.
public struct LeaseGrantedPayload: Sendable, Codable, Hashable {
    public var leaseId: LeaseId
    public var permission: String
    public var resource: String
    public var operation: String
    public var expiresAt: Date

    public init(
        leaseId: LeaseId,
        permission: String,
        resource: String,
        operation: String,
        expiresAt: Date
    ) {
        self.leaseId = leaseId
        self.permission = permission
        self.resource = resource
        self.operation = operation
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case leaseId = "lease_id"
        case permission, resource, operation
        case expiresAt = "expires_at"
    }
}

/// `lease.extended` payload. RFC §15.5.
public struct LeaseExtendedPayload: Sendable, Codable, Hashable {
    public var leaseId: LeaseId
    public var expiresAt: Date

    public init(leaseId: LeaseId, expiresAt: Date) {
        self.leaseId = leaseId
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case leaseId = "lease_id"
        case expiresAt = "expires_at"
    }
}

/// `lease.revoked` payload. RFC §15.5.
public struct LeaseRevokedPayload: Sendable, Codable, Hashable {
    public var leaseId: LeaseId
    public var reason: String

    public init(leaseId: LeaseId, reason: String) {
        self.leaseId = leaseId
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case leaseId = "lease_id"
        case reason
    }
}

/// `lease.refresh` payload. RFC §15.5.
public struct LeaseRefreshPayload: Sendable, Codable, Hashable {
    public var leaseId: LeaseId
    public var requestedSeconds: Int

    public init(leaseId: LeaseId, requestedSeconds: Int) {
        self.leaseId = leaseId
        self.requestedSeconds = requestedSeconds
    }

    enum CodingKeys: String, CodingKey {
        case leaseId = "lease_id"
        case requestedSeconds = "requested_seconds"
    }
}
