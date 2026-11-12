import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// "Als geprüft markieren": a selected unchecked booking becomes checked
/// immediately, after 1 or 5 seconds, or only by hand (default).
@MainActor
final class AutoReviewTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: AutoReviewDelay.defaultsKey)
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
        model.statusFilter = .all
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: AutoReviewDelay.defaultsKey)
        model = nil
    }

    /// Two unchecked bookings of the demo list (made unchecked if needed);
    /// nothing selected yet (the demo selects its first booking on load).
    private func uncheckedBookings() throws -> (Booking, Booking) {
        model.selectedBookingID = nil
        let list = Array(model.visibleBookings.prefix(2))
        XCTAssertEqual(list.count, 2)
        for b in list where b.checked { model.setChecked(false, for: b) }
        let fresh = list.compactMap { b in model.visibleBookings.first { $0.id == b.id } }
        XCTAssertTrue(fresh.allSatisfy { !$0.checked })
        return (fresh[0], fresh[1])
    }

    private func isChecked(_ b: Booking) -> Bool {
        model.visibleBookings.first { $0.id == b.id }?.checked ?? false
    }

    func testDefaultIsManualAndNothingIsMarked() async throws {
        XCTAssertEqual(model.autoReviewDelay, .manual)
        let (a, _) = try uncheckedBookings()
        model.selectedBookingID = a.id
        await model.autoReviewTask?.value
        XCTAssertFalse(isChecked(a))
    }

    func testImmediatelyMarksTheSelectedBooking() async throws {
        model.autoReviewDelay = .immediately
        let (a, _) = try uncheckedBookings()
        model.selectedBookingID = a.id
        await model.autoReviewTask?.value
        XCTAssertTrue(isChecked(a))
    }

    func testMovingOnBeforeTheDelayLeavesTheBookingUnchecked() async throws {
        model.autoReviewDelay = .oneSecond
        let (a, b) = try uncheckedBookings()
        model.selectedBookingID = a.id
        model.selectedBookingID = b.id
        await model.autoReviewTask?.value
        XCTAssertFalse(isChecked(a), "left before the second was over")
        XCTAssertTrue(isChecked(b))
    }

    func testMultipleSelectionIsNeverMarked() async throws {
        model.autoReviewDelay = .immediately
        let (a, b) = try uncheckedBookings()
        model.selectedBookingIDs = [a.id, b.id]
        model.selectedBookingID = a.id
        await model.autoReviewTask?.value
        XCTAssertFalse(isChecked(a))
        XCTAssertFalse(isChecked(b))
    }

    func testChoiceIsStoredPerDevice() {
        model.autoReviewDelay = .fiveSeconds
        XCTAssertEqual(UserDefaults.standard.string(forKey: AutoReviewDelay.defaultsKey), "5s")
        XCTAssertEqual(AutoReviewDelay.stored, .fiveSeconds)
        XCTAssertEqual(AutoReviewDelay.allCases.map(\.seconds), [nil, 0, 1, 5])
    }
}
