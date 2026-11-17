import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// Offline accounts and manual bookings (#679, #81): which accounts take bookings, and what the
/// editor's calls change. Run against the demo vault, which holds a cash account "Bargeld".
@MainActor
final class OfflineAccountsTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
        XCTAssertNil(model.errorMessage)
    }

    override func tearDown() async throws { model = nil }

    private var cash: Account { model.allAccounts.first { $0.name == "Bargeld" }! }

    private func setup(_ cents: Int64, _ who: String) -> ManualBookingSetup {
        ManualBookingSetup(bookingDate: DateText.iso(Date()), amountCents: cents, counterparty: who,
                           purpose: "", categoryId: nil, note: "")
    }

    /// All bookings of one account (the filter of the current view, narrowed to that account).
    private func bookings(of id: Int64) throws -> [Booking] {
        var filter = model.currentFilter
        filter.accountIds = [id]
        filter.limit = 1000
        return try XCTUnwrap(model.vault).listTransactions(filter: filter).transactions
    }

    private func awaitBalance(of id: Int64, _ cents: Int64) async throws {
        for _ in 0..<300 {
            if model.account(for: id)?.balanceCents == cents { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The sidebar did not show the new balance")
    }

    func testOnlyAccountsWithoutBankConnectionTakeBookings() {
        XCTAssertEqual(model.offlineAccounts.map(\.name), ["Bargeld"])
        XCTAssertTrue(model.isOffline(cash.id))
        let giro = model.allAccounts.first { $0.name == "Musterbank Girokonto" }!
        XCTAssertFalse(model.isOffline(giro.id))
        XCTAssertTrue(model.canAddManualBooking)
    }

    func testSelectingTheOfflineAccountOffersItsBookingForNewEntries() {
        XCTAssertNil(model.selectedOfflineAccount)
        model.sidebarSelection = .account(cash.id)
        XCTAssertEqual(model.selectedOfflineAccount?.id, cash.id)
        model.openManualBooking()
        XCTAssertEqual(model.offlineStore.bookingRequest?.accountId, cash.id)
        XCTAssertNil(model.offlineStore.bookingRequest?.booking)
    }

    func testSavingABookingMovesTheBalanceAndTheBookingCanBeDeleted() async throws {
        let before = cash.balanceCents
        let id = try model.saveManualBooking(accountId: cash.id, bookingId: nil, setup: setup(-10_00, "Kiosk"))
        try await awaitBalance(of: cash.id, before - 10_00)
        let b = try XCTUnwrap(try bookings(of: cash.id).first { $0.id == id })
        XCTAssertEqual(b.counterparty, "Kiosk")
        XCTAssertTrue(model.isManuallyEditable(b))

        model.deleteManualBooking(b)
        try await awaitBalance(of: cash.id, before)
    }

    func testBookingsOfBankAccountsAreNotEditableButCanBeMirrored() async throws {
        let giro = model.allAccounts.first { $0.name == "Musterbank Girokonto" }!
        let booking = try XCTUnwrap(try bookings(of: giro.id).first { $0.amountCents < 0 })
        XCTAssertFalse(model.isManuallyEditable(booking))
        let before = cash.balanceCents
        model.mirror(booking, to: cash)
        XCTAssertNil(model.errorMessage)
        try await awaitBalance(of: cash.id, before - booking.amountCents)
    }

    func testBalanceCorrectionBooksTheDifference() async throws {
        let before = cash.balanceCents
        model.correctBalance(cash.id, to: before + 7_50)
        try await awaitBalance(of: cash.id, before + 7_50)
        model.correctBalance(cash.id, to: before + 7_50)
        XCTAssertEqual(model.toast, String(localized: "Der Saldo stimmt bereits."))
    }

    func testAnInvalidBookingReportsTheCoreError() {
        XCTAssertThrowsError(try model.saveManualBooking(accountId: cash.id, bookingId: nil, setup: setup(0, "x")))
    }

    func testAccountNoteSurvivesAReloadOfTheAccounts() async throws {
        let id = cash.id
        model.setAccountNote("Reisekasse", for: id)
        model.reloadAccounts()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.accountNote(for: id), "Reisekasse")
    }
}
