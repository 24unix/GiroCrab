import XCTest
import GiroCrabCore
@testable import GiroCrabUI

final class AccountSelectionTests: XCTestCase {
    private func choice(_ ref: String, enabled: Bool, pending: Bool = false) -> ConnectionAccountChoice {
        ConnectionAccountChoice(accountRef: ref, name: ref, number: "", owner: "", enabled: enabled, pending: pending, existingConnection: "")
    }

    func testSwitchingOffAnEnabledAccountIsDetected() {
        let rows = [choice("A", enabled: true), choice("B", enabled: true)]
        XCTAssertTrue(AccountSelectionList.switchesAnythingOff(rows, enabled: ["A"]))
    }

    func testUnchangedOrOnlySwitchedOnIsNotSwitchingOff() {
        let rows = [choice("A", enabled: true), choice("B", enabled: false)]
        XCTAssertFalse(AccountSelectionList.switchesAnythingOff(rows, enabled: ["A"]))
        XCTAssertFalse(AccountSelectionList.switchesAnythingOff(rows, enabled: ["A", "B"]))
    }

    func testAHeldBackAccountThatStaysOffIsNotSwitchingOff() {
        let rows = [choice("A", enabled: true), choice("KIND", enabled: false, pending: true)]
        XCTAssertFalse(AccountSelectionList.switchesAnythingOff(rows, enabled: ["A"]))
    }

    @MainActor
    func testTheDraftOnlyHasChangesAfterTheSelectionDiffersFromWhatWasLoaded() {
        let draft = AccountSelectionDraft()
        XCTAssertFalse(draft.hasChanges, "nothing loaded yet")
        draft.adopt([choice("A", enabled: true), choice("B", enabled: true)])
        XCTAssertFalse(draft.hasChanges)
        draft.enabled.remove("B")
        XCTAssertTrue(draft.hasChanges, "switched off")
        draft.enabled.insert("B")
        XCTAssertFalse(draft.hasChanges, "switched back on: nothing to save")
    }

    @MainActor
    func testAHeldBackAccountSwitchedOnIsAChange() {
        let draft = AccountSelectionDraft()
        draft.adopt([choice("A", enabled: true), choice("KIND", enabled: false, pending: true)])
        XCTAssertFalse(draft.hasChanges)
        draft.enabled.insert("KIND")
        XCTAssertTrue(draft.hasChanges)
    }
}
