import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// Tagesgeld as the sender of an internal transfer (GitHub #582).
@MainActor
final class SavingsTransferSourceTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
    }

    override func tearDown() async throws { model = nil }

    func testSavingsSourcesAreKeptOutOfTheOtherTransferForms() {
        let savings = Set(model.savingsTransferSources.map(\.id))
        XCTAssertTrue(savings.isDisjoint(with: model.transferAccounts.map(\.id)))
        XCTAssertTrue(model.savingsTransferSources.allSatisfy { $0.kind == .savings })
        XCTAssertTrue(savings.isSubset(of: model.transferFormAccounts.map(\.id)))
        XCTAssertTrue(savings.isDisjoint(with: model.giroCodeAccounts.map(\.id)))
    }

    func testSavingsAccountTransfersOnlyToOwnCheckingAccounts() throws {
        let source = try XCTUnwrap(model.allAccounts.first { $0.kind == .savings && !$0.iban.isEmpty })
        let targets = model.internalTransferTargets(from: source)
        XCTAssertFalse(targets.isEmpty)
        XCTAssertTrue(targets.allSatisfy { $0.kind == .checking && !$0.iban.isEmpty && $0.id != source.id })
    }
}
