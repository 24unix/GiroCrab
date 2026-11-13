import XCTest
@testable import GiroCrabUI

final class AppVersionDisplayTests: XCTestCase {
    func testMatchingVersionsShowBuild() {
        XCTAssertEqual(AppVersionDisplay.text(core: "0.6.2", bundleVersion: "0.6.2", build: "14"), "0.6.2 (Build 14)")
    }

    func testPinnedTestFlightVersionShowsBoth() {
        XCTAssertEqual(AppVersionDisplay.text(core: "0.6.2", bundleVersion: "0.6.1", build: "14"),
                       "0.6.2 (TestFlight 0.6.1 · Build 14)")
    }

    func testNonNumericBuildIsNotRepeated() {
        XCTAssertEqual(AppVersionDisplay.text(core: "0.6.2", bundleVersion: "0.6.2", build: "0.6.2"), "0.6.2")
        XCTAssertEqual(AppVersionDisplay.text(core: "0.6.2", bundleVersion: nil, build: nil), "0.6.2")
    }
}
