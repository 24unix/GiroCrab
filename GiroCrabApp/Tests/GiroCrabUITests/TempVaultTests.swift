import XCTest
@testable import GiroCrabUI

/// `swift test --parallel` runs the suites in several processes at once:
/// each needs its own demo and fresh vault file, or they lock each other
/// ("database is locked"). The app keeps one fixed file (`--keep-fresh-vault`).
final class TempVaultTests: XCTestCase {
    func testTestRunsGetOneFilePerProcess() {
        XCTAssertEqual(AppModel.tempVaultURL("GiroCrab-Demo", unitTests: true, pid: 4242).lastPathComponent,
                       "GiroCrab-Demo-4242.girocrab")
    }

    func testTheAppKeepsTheFixedName() {
        XCTAssertEqual(AppModel.tempVaultURL("GiroCrab-Fresh", unitTests: false, pid: 4242).lastPathComponent,
                       "GiroCrab-Fresh.girocrab")
    }

    func testThisTestRunUsesItsOwnFile() {
        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertEqual(AppModel.tempVaultURL("GiroCrab-Demo").lastPathComponent, "GiroCrab-Demo-\(pid).girocrab")
    }
}
