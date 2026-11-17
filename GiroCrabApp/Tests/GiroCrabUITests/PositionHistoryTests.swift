import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// The value history of depot positions (#578) as the depot view reads it from the demo vault.
@MainActor
final class PositionHistoryTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
    }

    override func tearDown() async throws { model = nil }

    private func depotData(_ name: String) async throws -> DepotData {
        let depot = try XCTUnwrap(model.allAccounts.first { $0.name == name })
        let id = depot.id
        let loaded = try await model.vaultOffMain { vault in
            (try vault.classifiedAssets(accountId: id), try vault.depotValuePositions(accountId: id))
        }
        let (assets, positions) = try XCTUnwrap(loaded)
        return DepotData(accountId: id, revision: model.vaultRevision, assets: assets, transactions: [],
                         valuePoints: [], valuePositions: positions)
    }

    func testEveryHeldPositionOpensItsHistoryAndTheSoldOneIsListedApart() async throws {
        let data = try await depotData("Welt-Depot ETF")
        let held = DepotPosition.make(data.assets)
        XCTAssertFalse(held.isEmpty)
        for p in held {
            XCTAssertEqual(data.valuePosition(p)?.position, p.holding.isin, "history of \(p.holding.isin)")
        }
        XCTAssertEqual(data.soldPositions.map(\.position), ["IE00BKM4GZ66"])
        XCTAssertEqual(data.soldPositions.first?.lastValueCents, 0)
    }

    func testASoldPositionsHistoryEndsWithItsSale() async throws {
        let data = try await depotData("Welt-Depot ETF")
        let sold = try XCTUnwrap(data.soldPositions.first)
        let id = data.accountId, key = sold.position
        let loaded = try await model.vaultOffMain { try $0.positionValueHistory(accountId: id, position: key) }
        let points = try XCTUnwrap(loaded)
        XCTAssertEqual(points.last?.date, sold.lastDate)
        XCTAssertEqual(points.last?.valueCents, 0)
        XCTAssertTrue(points.dropLast().allSatisfy { $0.valueCents > 0 })
    }
}
