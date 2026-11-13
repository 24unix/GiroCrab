import XCTest
@testable import GiroCrabUI

final class QuirionFailureStreakTests: XCTestCase {
    func testStopsAfterThreeConsecutiveFailures() {
        var streak = QuirionFailureStreak()
        XCTAssertFalse(streak.failed())
        XCTAssertFalse(streak.failed())
        XCTAssertTrue(streak.failed())
    }

    func testSuccessResetsTheStreak() {
        var streak = QuirionFailureStreak()
        _ = streak.failed()
        _ = streak.failed()
        streak.succeeded()
        XCTAssertFalse(streak.failed())
        XCTAssertFalse(streak.failed())
        XCTAssertTrue(streak.failed())
    }
}
