import XCTest
@testable import GiroCrabUI

/// Budgets can be hidden completely (Ansicht › Budgets anzeigen).
final class BudgetVisibilityTests: XCTestCase {
    func testBudgetsShowUntilSwitchedOff() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "BudgetVisibilityTests"))
        defaults.removePersistentDomain(forName: "BudgetVisibilityTests")
        XCTAssertTrue(ViewLayout.showsBudgets(defaults))
        defaults.set(false, forKey: ViewLayout.budgetsKey)
        XCTAssertFalse(ViewLayout.showsBudgets(defaults))
        defaults.removePersistentDomain(forName: "BudgetVisibilityTests")
    }

    /// Each card follows its own switch: budgets stay when the analytics
    /// (Ansicht › Auswertungen anzeigen) are off, and the other way round.
    func testBudgetsDoNotDependOnAnalytics() {
        XCTAssertEqual(ViewLayout.cards(statistics: false, budgets: true).budgets, true)
        XCTAssertEqual(ViewLayout.cards(statistics: false, budgets: true).cashflow, false)
        XCTAssertEqual(ViewLayout.cards(statistics: true, budgets: false).cashflow, true)
        XCTAssertEqual(ViewLayout.cards(statistics: true, budgets: false).budgets, false)
        XCTAssertFalse(ViewLayout.cards(statistics: false, budgets: false).any)
    }
}
