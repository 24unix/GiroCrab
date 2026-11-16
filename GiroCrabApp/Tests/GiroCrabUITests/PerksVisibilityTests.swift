import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// #735: the "Trade Republic Perks" card and the Saveback / Round up KPIs only
/// show when such bookings exist.
final class PerksVisibilityTests: XCTestCase {
    private func dashboard(saveback: UInt32, roundup: UInt32) -> InvestmentDashboard {
        InvestmentDashboard(
            months: [], plans: [], totalMonthlyCents: 0,
            savebackEarnedCents: Int64(saveback) * 100, savebackCount: saveback,
            roundupInvestedCents: Int64(roundup) * 50, roundupCount: roundup,
            perksThisMonthCents: 0, monthly: [])
    }

    func testNoPerkBookingsHidesPerks() {
        XCTAssertFalse(dashboard(saveback: 0, roundup: 0).hasPerks)
    }

    func testSavebackOrRoundupShowsPerks() {
        XCTAssertTrue(dashboard(saveback: 1, roundup: 0).hasPerks)
        XCTAssertTrue(dashboard(saveback: 0, roundup: 3).hasPerks)
        XCTAssertTrue(dashboard(saveback: 2, roundup: 2).hasPerks)
    }
}
