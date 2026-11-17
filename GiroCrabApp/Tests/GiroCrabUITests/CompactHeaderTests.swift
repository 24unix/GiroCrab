import XCTest
@testable import GiroCrabUI

/// The header card can be minimised (Ansicht › Kopfbereich minimieren, GitHub #358).
final class CompactHeaderTests: XCTestCase {
    func testHeaderShowsInFullUntilMinimised() throws {
        let suite = "CompactHeaderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        XCTAssertFalse(ViewLayout.compactHeader(defaults))
        defaults.set(true, forKey: ViewLayout.compactHeaderKey)
        XCTAssertTrue(ViewLayout.compactHeader(defaults))
        defaults.removePersistentDomain(forName: suite)
    }
}
