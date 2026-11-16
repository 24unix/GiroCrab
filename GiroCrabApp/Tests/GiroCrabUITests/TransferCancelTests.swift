import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// Cancelling the TAN request of a batch transfer or a collection run: the run's own sheet comes
/// back and its flag is cleared, so the next single transfer does not end as a batch or a collection.
@MainActor
final class TransferCancelTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
    }

    override func tearDown() async throws { model = nil }

    private func batchSession() throws -> TransferSession {
        clearBankingBlock()  // the policy check cannot reach the network in a test run
        let account = try XCTUnwrap(model.batchAccounts.first)
        let payment = BatchPaymentInput(name: "Anna Becker", iban: "DE89370400440532013000", bic: nil, amountCents: 6_000, purpose: "Beitrag")
        let request = BatchTransferRequest(accountId: account.id, payments: [payment], batchBooking: true, executionDate: nil)
        return try XCTUnwrap(model.vault).beginBatchTransfer(request: request, secret: "demo", demo: true)
    }

    func testCancellingABatchBringsItsSheetBack() throws {
        model.activeTransfer = try batchSession()
        model.activeTransferIsBatch = true
        model.transferBusy = true
        model.cancelSync()
        XCTAssertFalse(model.activeTransferIsBatch)
        XCTAssertNil(model.activeTransfer)
        XCTAssertFalse(model.transferBusy)
        XCTAssertTrue(model.showBatchSheet)
        XCTAssertFalse(model.showTransferSheet, "not the single transfer form")
        XCTAssertNotNil(model.transferError)
    }

    func testCancellingACollectionRunClearsItsState() throws {
        model.activeTransfer = try batchSession()
        model.activeTransferIsDebit = true
        model.debitRun = DebitRun(accountID: 1, items: [], due: "2026-12-01", remaining: [], total: 1,
                                  batchBooking: true, b2bConfirmed: false, pin: "1234")
        model.transferBusy = true
        model.cancelSync()
        XCTAssertFalse(model.activeTransferIsDebit)
        XCTAssertNil(model.debitRun)
        XCTAssertTrue(model.showCollectionSheet)
        XCTAssertFalse(model.showTransferSheet)
        XCTAssertNotNil(model.mandateError)
    }
}
