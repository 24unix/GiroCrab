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
}
