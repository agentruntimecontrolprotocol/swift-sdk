import Foundation

/// Validates the §9.4 subset constraints a delegated (child) lease must
/// satisfy relative to its parent.
///
/// §9.4 imposes three constraints on a delegated lease:
/// 1. `model.use` MUST be a subset of the parent's allowed patterns.
/// 2. `cost.budget` MUST NOT exceed the parent's **remaining** budget per
///    currency (max − already spent).
/// 3. `lease_constraints.expires_at` MUST NOT exceed the parent's.
///
/// A violation of any constraint is reported as `LEASE_SUBSET_VIOLATION`.
///
/// Note: ARCP `delegate` events (§10) are not yet implemented in this SDK —
/// `MessageType` has no `delegate` case and unknown types are nack'd. This
/// validator is the building block any future delegation path MUST invoke;
/// it is exercised directly by tests today.
public enum LeaseSubsetting {
    /// Throw `ARCPError.leaseSubsetViolation` when `child` is not a valid
    /// subset of `parent` per §9.4.
    ///
    /// - Parameters:
    ///   - parent: The parent lease envelope.
    ///   - child: The requested child (delegated) lease.
    ///   - parentRemaining: Per-currency remaining budget on the parent
    ///     (`max − spent`). A currency absent here is treated as fully unspent.
    public static func assertSubset(
        parent: LeaseSnapshot,
        child: LeaseSnapshot,
        parentRemaining: [String: Double] = [:]
    ) throws {
        // (1) model.use subset.
        try ModelUsePolicy.assertSubset(parent: parent.modelUse, child: child.modelUse)

        // (2) cost.budget MUST NOT exceed the parent's remaining budget.
        if let childBudget = child.costBudget, !childBudget.isEmpty {
            let parentBudget = parent.costBudget ?? CostBudget()
            if let violation = parentBudget.subsetViolation(
                of: childBudget,
                remaining: parentRemaining
            ) {
                throw ARCPError.leaseSubsetViolation(
                    detail: "cost.budget \(violation) exceeds parent remaining budget"
                )
            }
        }

        // (3) expires_at MUST NOT exceed the parent's. A bounded parent
        // requires the child to be bounded and no later; an unbounded parent
        // permits any (more restrictive) child expiry.
        if let parentExpiry = parent.expiresAt {
            guard let childExpiry = child.expiresAt, childExpiry <= parentExpiry else {
                throw ARCPError.leaseSubsetViolation(
                    detail: "lease_constraints.expires_at exceeds parent lease"
                )
            }
        }
    }
}
