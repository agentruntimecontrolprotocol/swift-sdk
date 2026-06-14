import Foundation
import Testing

@testable import ARCP

@Suite("Lease subset / delegation (§9.4)")
struct LeaseSubsettingTests {
    private func budget(_ usd: Double) -> CostBudget {
        CostBudget(amounts: [CostBudgetAmount(currency: "USD", amount: usd)])
    }

    @Test("A child within model.use, budget, and expiry is accepted")
    func validSubset() throws {
        let parent = LeaseSnapshot(
            costBudget: budget(10),
            modelUse: ModelUse(patterns: ["openai/*"]),
            expiresAt: Date(timeIntervalSinceNow: 100)
        )
        let child = LeaseSnapshot(
            costBudget: budget(5),
            modelUse: ModelUse(patterns: ["openai/gpt-4o"]),
            expiresAt: Date(timeIntervalSinceNow: 50)
        )
        try LeaseSubsetting.assertSubset(parent: parent, child: child)
    }

    @Test("A child exceeding parent remaining budget is rejected")
    func budgetExceedsRemaining() {
        let parent = LeaseSnapshot(costBudget: budget(10))
        let child = LeaseSnapshot(costBudget: budget(8))
        // Parent has spent 5 → only 5 remaining; child wants 8.
        #expect(throws: ARCPError.self) {
            try LeaseSubsetting.assertSubset(
                parent: parent,
                child: child,
                parentRemaining: ["USD": 5]
            )
        }
    }

    @Test("A child expires_at later than the parent is rejected")
    func expiryExceedsParent() {
        let parent = LeaseSnapshot(expiresAt: Date(timeIntervalSinceNow: 50))
        let child = LeaseSnapshot(expiresAt: Date(timeIntervalSinceNow: 500))
        #expect(throws: ARCPError.self) {
            try LeaseSubsetting.assertSubset(parent: parent, child: child)
        }
    }

    @Test("A bounded parent rejects an unbounded child")
    func unboundedChildRejected() {
        let parent = LeaseSnapshot(expiresAt: Date(timeIntervalSinceNow: 50))
        let child = LeaseSnapshot(modelUse: ModelUse(patterns: ["openai/*"]))
        #expect(throws: ARCPError.self) {
            try LeaseSubsetting.assertSubset(parent: parent, child: child)
        }
    }

    @Test("A child model.use outside the parent patterns is rejected")
    func modelUseExceedsParent() {
        let parent = LeaseSnapshot(modelUse: ModelUse(patterns: ["openai/*"]))
        let child = LeaseSnapshot(modelUse: ModelUse(patterns: ["anthropic/claude"]))
        #expect(throws: ARCPError.self) {
            try LeaseSubsetting.assertSubset(parent: parent, child: child)
        }
    }
}
