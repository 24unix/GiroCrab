import XCTest
@testable import GiroCrabUI

/// "Tresor-Schlüssel kopieren" counts down the 60 s the key stays on the
/// clipboard, then offers copying again (#909: "(60 s)" stayed forever).
final class KeyCopyCountdownTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000)

    func testFullMinuteRightAfterCopying() {
        XCTAssertEqual(KeyCopyCountdown.secondsLeft(until: now.addingTimeInterval(60), now: now), 60)
    }

    func testPartSecondsRoundUp() {
        XCTAssertEqual(KeyCopyCountdown.secondsLeft(until: now.addingTimeInterval(41.2), now: now), 42)
    }

    func testNothingLeftAfterTheMinute() {
        XCTAssertNil(KeyCopyCountdown.secondsLeft(until: now, now: now))
        XCTAssertNil(KeyCopyCountdown.secondsLeft(until: now.addingTimeInterval(-5), now: now))
        XCTAssertNil(KeyCopyCountdown.secondsLeft(until: nil, now: now))
    }

    func testLabelShowsTheSecondsAndFallsBack() {
        XCTAssertEqual(KeyCopyCountdown.title(secondsLeft: nil), "Tresor-Schlüssel kopieren")
        let counting = KeyCopyCountdown.title(secondsLeft: 42)
        XCTAssertTrue(counting.contains("42"), counting)
        XCTAssertTrue(counting.contains("Zwischenablage"), counting)
    }
}
