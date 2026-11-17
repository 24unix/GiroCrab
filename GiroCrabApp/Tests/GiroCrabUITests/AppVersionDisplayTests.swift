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

final class AppVersionTests: XCTestCase {
    func testBundleVersionWithBuild() {
        XCTAssertEqual(AppVersion.text(bundleVersion: "0.7.5", build: "18", core: "0.7.5"), "GiroCrab 0.7.5 (18)")
    }

    func testBuildEqualToVersionIsNotRepeated() {
        XCTAssertEqual(AppVersion.text(bundleVersion: "0.7.5", build: "0.7.5", core: "0.7.5"), "GiroCrab 0.7.5")
    }

    func testSwiftRunFallsBackToCargoVersion() {
        XCTAssertEqual(AppVersion.text(bundleVersion: nil, build: nil, core: "0.7.5"), "GiroCrab 0.7.5 (dev)")
        XCTAssertEqual(AppVersion.text(bundleVersion: " ", build: "1", core: "0.7.5"), "GiroCrab 0.7.5 (dev)")
    }

    func testDevFallbackUsesWorkspaceVersion() {
        XCTAssertTrue(AppVersion.displayString.hasPrefix("GiroCrab "))
    }
}

final class BankingPolicyVersionTests: XCTestCase {
    func testMacBuildStringIsUsedAsIs() {
        XCTAssertEqual(BankingVersion.policyVersion(build: "0.8.0", marketing: "0.8.0", core: "0.8.0"), "0.8.0")
        XCTAssertEqual(BankingVersion.policyVersion(build: "0.8.0.123", marketing: "0.8.0", core: "0.8.0"), "0.8.0.123")
    }

    func testIOSBuildCounterFallsBackToCoreVersion() {
        // "20" alone would compare newer than every minimumVersion
        XCTAssertEqual(BankingVersion.policyVersion(build: "20", marketing: "0.6.1", core: "0.8.0"), "0.8.0")
        XCTAssertEqual(BankingVersion.compare(
            BankingVersion.policyVersion(build: "20", marketing: "0.6.1", core: "0.7.5"), "0.8.0"), .orderedAscending)
    }

    func testFallsBackToMarketingVersionWithoutCore() {
        XCTAssertEqual(BankingVersion.policyVersion(build: "20", marketing: "0.6.1", core: ""), "0.6.1")
    }
}
