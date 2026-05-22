import Foundation

/// Per-job `cost.budget` counters (ARCP v1.1 §9.6).
///
/// Tracks remaining authority for each declared currency. The agent
/// reports cost; the runtime decrements counters on each
/// ``JobContext/charge(name:amount:currency:)`` call. Once a counter
/// falls to ≤ 0, further charges raise ``ARCPError/budgetExhausted``.
///
/// A tracker constructed via ``init()`` (no declared budget) is
/// "disabled" — charges to unknown currencies are silently ignored
/// per §9.6 ("unreported / unbudgeted costs are not enforced").
public final class BudgetTracker: @unchecked Sendable {
    private let lock = NSLock()
    // currency → (max, consumed)
    private var state: [String: (max: Double, consumed: Double)]

    /// Empty tracker — no currencies, no enforcement.
    public init() {
        self.state = [:]
    }

    /// Tracker seeded from a ``CostBudget`` lease capability.
    public init(budget: CostBudget) {
        var s: [String: (Double, Double)] = [:]
        for a in budget.amounts {
            s[a.currency] = (a.amount, 0)
        }
        self.state = s
    }

    /// True when no currencies are tracked.
    public var isDisabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.isEmpty
    }

    /// Remaining budget for `currency`, if tracked. `nil` means the
    /// currency was not declared on the lease.
    public func remaining(for currency: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = state[currency] else { return nil }
        return entry.max - entry.consumed
    }

    /// Snapshot of remaining-per-currency.
    public func snapshotRemaining() -> [String: Double] {
        lock.lock()
        defer { lock.unlock() }
        return state.mapValues { $0.max - $0.consumed }
    }

    /// Charge `amount` to `currency`. Returns the remaining counter
    /// after the decrement. Negative or non-finite amounts raise
    /// ``ARCPError/invalidArgument(field:detail:)``. When the counter
    /// would drop below zero the call raises
    /// ``ARCPError/budgetExhausted(detail:)``.
    ///
    /// Currencies absent from the declared lease are silently ignored
    /// and return `Double.infinity`.
    @discardableResult
    public func charge(currency: String, amount: Double) throws -> Double {
        if !amount.isFinite || amount < 0 {
            throw ARCPError.invalidArgument(
                field: "amount",
                detail: "negative or non-finite cost amount: \(amount)"
            )
        }
        lock.lock()
        defer { lock.unlock() }
        guard var entry = state[currency] else {
            // Not budgeted → unbounded.
            return .infinity
        }
        let remainingBefore = entry.max - entry.consumed
        if remainingBefore <= 0 || amount > remainingBefore {
            throw ARCPError.budgetExhausted(
                detail: "\(currency) budget exhausted (remaining=\(remainingBefore))"
            )
        }
        entry.consumed += amount
        state[currency] = entry
        return entry.max - entry.consumed
    }
}
