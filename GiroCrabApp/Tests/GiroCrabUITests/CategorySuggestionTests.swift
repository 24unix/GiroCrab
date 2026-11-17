import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// "Vorschlag (aus Historie)" (#664): the selected uncategorised booking is
/// offered the category of its payee's earlier bookings, loaded in the background.
@MainActor
final class CategorySuggestionTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
        XCTAssertNil(model.errorMessage)
    }

    override func tearDown() async throws { model = nil }

    /// A booking of the merchant with the most checked rule bookings of one
    /// category, made uncategorised by hand, with the category it had.
    private func clearedBooking() throws -> (Booking, Int64) {
        let history = model.bookings.filter { $0.categorySource == .rule && $0.checked && $0.flow != .transfer }
        let clear = Dictionary(grouping: history, by: \.merchant.key)
            .filter { Set($0.value.map(\.categoryId)).count == 1 }
        let rows = try XCTUnwrap(clear.values.max { $0.count < $1.count })
        XCTAssertGreaterThanOrEqual(rows.count, 3, "the demo needs a merchant with history")
        let booking = rows[0], category = try XCTUnwrap(booking.categoryId)
        model.setCategory(nil, for: booking)
        return (try XCTUnwrap(model.booking(withID: booking.id)), category)
    }

    private func awaitSuggestion(for id: Int64) async throws -> CategorySuggestion {
        for _ in 0..<300 {
            if let s = model.categorySuggestion, s.bookingId == id { return s }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(nil as CategorySuggestion?, "no suggestion for the selected booking")
    }

    func testSelectedBookingGetsItsHistorysCategoryAndAcceptingAssignsIt() async throws {
        let (booking, category) = try clearedBooking()
        XCTAssertNil(booking.categoryId)
        model.selectedBookingID = booking.id
        let s = try await awaitSuggestion(for: booking.id)
        XCTAssertEqual(s.categoryId, category)
        XCTAssertGreaterThanOrEqual(s.support, 2)
        XCTAssertLessThanOrEqual(s.support, s.considered)

        // "Als Regel …" starts from the suggested category, not the empty one
        let draft = CategorySuggestionBox.ruleDraft(model.newRuleDraft(from: booking), booking: booking, suggestion: s)
        XCTAssertEqual(draft.categoryId, category)

        // "Übernehmen": a manual category, and the suggestion is gone at once
        model.setCategory(s.categoryId, for: booking)
        XCTAssertNil(model.categorySuggestion)
        let now = try XCTUnwrap(model.booking(withID: booking.id))
        XCTAssertEqual(now.categoryId, category)
        XCTAssertEqual(now.categorySource, .manual)
    }

    func testCategorisedGetsNoneAndSelectionChangesKeepIt() async throws {
        let (booking, _) = try clearedBooking()
        model.selectedBookingID = booking.id
        _ = try await awaitSuggestion(for: booking.id)

        let other = try XCTUnwrap(model.bookings.first { $0.id != booking.id && $0.categoryId != nil })
        model.selectedBookingID = other.id
        XCTAssertNil(model.categorySuggestion, "a categorised booking gets no suggestion")

        model.selectedBookingID = booking.id
        _ = try await awaitSuggestion(for: booking.id)
        model.selectedBookingID = booking.id
        XCTAssertNotNil(model.categorySuggestion, "clicking the selected row again keeps it")

        // a multiple selection shows its own card; back to one booking, the suggestion is still there
        model.selectedBookingID = other.id
        model.selectBooking(booking.id, toggle: true)
        XCTAssertEqual(model.selectedBookingID, booking.id)
        model.selectBooking(other.id, toggle: true)
        XCTAssertEqual(model.selectedBookingID, booking.id)
        _ = try await awaitSuggestion(for: booking.id)
    }

    func testRuleFromAnIBANSuggestionMatchesTheIBAN() throws {
        let booking = try XCTUnwrap(model.bookings.first { !$0.counterpartyIban.isEmpty })
        let base = model.newRuleDraft(from: booking)
        func draft(_ basis: SuggestionBasis) -> Rule {
            let s = CategorySuggestion(bookingId: booking.id, categoryId: 7, basis: basis, support: 2, considered: 2)
            return CategorySuggestionBox.ruleDraft(base, booking: booking, suggestion: s)
        }
        XCTAssertEqual(draft(.iban).field, .counterpartyIban)
        XCTAssertEqual(draft(.iban).pattern, booking.counterpartyIban.filter { !$0.isWhitespace })
        XCTAssertEqual(draft(.iban).categoryId, 7)
        XCTAssertEqual(draft(.merchant).field, base.field)
        XCTAssertEqual(draft(.merchant).pattern, base.pattern)
    }

    func testListRowsGetTheirSuggestionsInOneCall() async throws {
        let (booking, category) = try clearedBooking()
        for _ in 0..<300 {
            if model.listSuggestions[booking.id] != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.listSuggestions[booking.id]?.categoryId, category)
        XCTAssertTrue(model.listSuggestions.keys.allSatisfy { id in model.booking(withID: id)?.categoryId == nil },
                      "only uncategorised rows get one")

        // accepting it (row menu) assigns the category; the row drops its hint
        model.setCategory(category, for: booking)
        XCTAssertEqual(model.booking(withID: booking.id)?.categoryId, category)
    }
}
