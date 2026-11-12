import XCTest
@testable import GiroCrabUI

/// Dock badge: the number of unchecked bookings of the own vault, kept as the
/// last known state while the vault is locked or the demo is shown.
final class DockBadgeTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "DockBadgeTests"

    override func setUp() {
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = nil
    }

    func testLabelShowsTheCountAndNothingAtZero() {
        XCTAssertNil(DockBadge.label(0))
        XCTAssertEqual(DockBadge.label(1), "1")
        XCTAssertEqual(DockBadge.label(1234), "1234")
    }

    func testOwnVaultCountIsRecorded() {
        let badge = DockBadge(defaults: defaults)
        XCTAssertEqual(badge.count, 0)
        XCTAssertTrue(badge.record(7, ownVaultOpen: true))
        XCTAssertEqual(badge.count, 7)
        XCTAssertFalse(badge.record(7, ownVaultOpen: true), "unchanged")
        XCTAssertTrue(badge.record(0, ownVaultOpen: true))
        XCTAssertEqual(badge.count, 0)
    }

    func testLockedOrDemoKeepsTheLastKnownState() {
        let badge = DockBadge(defaults: defaults)
        badge.record(5, ownVaultOpen: true)
        // locking empties the account list: the count must not drop to 0
        XCTAssertFalse(badge.record(0, ownVaultOpen: false))
        XCTAssertEqual(badge.count, 5)
        // demo data never replaces the own vault's count
        XCTAssertFalse(badge.record(42, ownVaultOpen: false))
        XCTAssertEqual(badge.count, 5)
    }

    func testLastKnownStateSurvivesARelaunch() {
        DockBadge(defaults: defaults).record(3, ownVaultOpen: true)
        XCTAssertEqual(DockBadge(defaults: defaults).count, 3)
    }
}
