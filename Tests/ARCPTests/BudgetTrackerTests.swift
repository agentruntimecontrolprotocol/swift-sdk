import Foundation
import Testing

@testable import ARCP

@Suite("cost.budget (ARCP v1.1 §9.6)")
struct BudgetTrackerTests {
    @Test("BudgetTracker.charge decrements and returns remaining")
    func chargeDecrements() throws {
        let tracker = BudgetTracker(budget: .from(["USD": 1.0]))
        #expect(try tracker.charge(currency: "USD", amount: 0.4) == 0.6)
    }

    @Test("BudgetTracker.charge raises budgetExhausted on overspend")
    func chargeRejectsOverspend() throws {
        let tracker = BudgetTracker(budget: .from(["USD": 0.5]))
        #expect(throws: ARCPError.self) {
            try tracker.charge(currency: "USD", amount: 0.6)
        }
    }

    @Test("Disabled tracker accepts unknown currencies and returns infinity")
    func disabledTrackerIsUnbounded() throws {
        let tracker = BudgetTracker()
        #expect(try tracker.charge(currency: "credits", amount: 100).isInfinite)
    }

    @Test("Negative or non-finite amount raises INVALID_ARGUMENT")
    func invalidAmount() {
        let tracker = BudgetTracker(budget: .from(["USD": 1]))
        #expect(throws: ARCPError.self) {
            try tracker.charge(currency: "USD", amount: -1)
        }
    }

    @Test("CostBudget.subsetViolation flags currency that exceeds parent")
    func subsetViolation() {
        let parent = CostBudget.from(["USD": 1])
        #expect(parent.subsetViolation(of: .from(["USD": 2])) == "USD")
        #expect(parent.subsetViolation(of: .from(["USD": 0.5])) == nil)
    }

    @Test("CostBudget Codable round-trip uses array-of-strings wire form")
    func codableRoundTrip() throws {
        let budget = CostBudget.from(["USD": 5])
        let data = try JSONEncoder().encode(budget)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String])
        #expect(raw == ["USD:5"])
        #expect(try JSONDecoder().decode(CostBudget.self, from: data) == budget)
    }
}
