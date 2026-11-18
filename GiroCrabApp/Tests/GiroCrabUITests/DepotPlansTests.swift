import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// The savings plans tab of a depot: search and paging, on the demo depot with two ETF plans.
@MainActor
final class DepotPlansTests: XCTestCase {
    private var model: AppModel!
    private var depot: Int64 = 0

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        depot = try XCTUnwrap(model.allAccounts.first { $0.name == "Welt-Depot ETF" }).id
    }

    private func plans(offset: UInt32 = 0) throws -> InvestmentDashboard {
        try XCTUnwrap(model.vault).depotSavingsPlans(accountId: depot, months: 6, endOffsetMonths: offset)
    }

    func testTheSearchKeepsTheMatchingPlansAndTheirTotals() throws {
        let all = try plans()
        XCTAssertEqual(all.plans.count, 2)
        XCTAssertEqual(DepotPlans.matching(all, query: "").plans.count, 2)
        let one = DepotPlans.matching(all, query: "vanguard")
        XCTAssertEqual(one.plans.map(\.merchant.name).count, 1)
        XCTAssertTrue(one.plans[0].merchant.name.lowercased().contains("vanguard"))
        XCTAssertEqual(one.totalMonthlyCents, one.plans.filter(\.active).reduce(0) { $0 + $1.monthlyCents })
        XCTAssertLessThan(one.totalMonthlyCents, all.totalMonthlyCents)
        // by ISIN as well
        XCTAssertEqual(DepotPlans.matching(all, query: all.plans[0].merchant.isin).plans.count, 1)
        XCTAssertTrue(DepotPlans.matching(all, query: "gibt es nicht").plans.isEmpty)
    }

    func testAnEarlierPageEndsBeforeTheNewest() throws {
        let now = try plans()
        let before = try plans(offset: 6)
        XCTAssertEqual(now.months.count, 6)
        XCTAssertEqual(before.months.count, 6)
        XCTAssertLessThan(try XCTUnwrap(before.months.last), try XCTUnwrap(now.months.first))
    }
}
