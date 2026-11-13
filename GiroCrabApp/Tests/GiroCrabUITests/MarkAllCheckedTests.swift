import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// "Alle als gelesen markieren" (GitHub #236): one SQL update, per account or for everything.
@MainActor
final class MarkAllCheckedTests: XCTestCase {
    private func demoModel() -> AppModel {
        AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
    }

    /// The update runs off the main thread; wait until the new count reaches `expected`.
    private func awaitNewCount(_ model: AppModel, _ expected: Int) async {
        for _ in 0..<300 {
            if model.newCount == expected { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.newCount, expected)
    }

    func testMarkAllMarksEverythingNew() async throws {
        let model = demoModel()
        XCTAssertGreaterThan(model.newCount, 0)
        model.markAllChecked(accountIDs: model.allAccounts.map(\.id))
        await awaitNewCount(model, 0)
        XCTAssertNil(model.errorMessage)
    }

    func testMarkAllForOneAccountLeavesOthers() async throws {
        let model = demoModel()
        let withNew = model.allAccounts.filter { $0.newCount > 0 }
        try XCTSkipIf(withNew.count < 2, "needs two accounts with new bookings")
        let others = withNew.dropFirst().reduce(0) { $0 + Int($1.newCount) }
        model.markAllChecked(accountIDs: [withNew[0].id])
        await awaitNewCount(model, others)
    }

    func testMarkAllOfTheListHonoursTheScope() async throws {
        let model = demoModel()
        model.scope = .investments
        let total = model.newCount
        XCTAssertGreaterThan(total, 0)
        model.markAllChecked()
        try await Task.sleep(for: .milliseconds(500))
        // the demo has no new investment bookings: nothing outside the list's scope may change
        XCTAssertEqual(model.newCount, total)
    }
}
