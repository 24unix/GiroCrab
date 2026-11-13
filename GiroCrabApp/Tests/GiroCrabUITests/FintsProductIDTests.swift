import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// Choice between GiroCrab's own FinTS registration and the user's (built in only by release builds).
@MainActor
final class FintsProductIDTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
    }

    override func tearDown() async throws { model = nil }

    func testOwnIDCountsAsRegistrationAndSurvivesTheSwitch() {
        model.saveSetting("fints.product_id", "OWN-TEST-ID")
        // not decided yet: existing users keep working with their own ID
        XCTAssertEqual(model.fintsProductIDMode, "")
        XCTAssertEqual(model.fintsProductIDSource, "own")

        model.setFintsProductIDMode("builtin")
        XCTAssertEqual(model.fintsProductIDMode, "builtin")
        // without an embedded ID (developer/test build) the own one stays the fallback
        XCTAssertEqual(model.fintsProductIDSource, model.fintsBuiltinAvailable ? "builtin" : "own")
        XCTAssertEqual(model.settingEntry("fints.product_id")?.hasValue, true, "own ID is never deleted")

        model.setFintsProductIDMode("own")
        XCTAssertEqual(model.fintsProductIDSource, "own")
        XCTAssertFalse(model.offerProductIDChoice)
    }

    /// Real Atruvia answer: the first code is 9050, the rejection (9078) only in the message.
    func testProductIDRejectionIsRecognisedFromTheMessage() {
        let atruvia = CoreError.Bank(code: "9050", message: "9050 [Nachricht] Die Nachricht enthält Fehler. / 9800 [Nachricht] Dialog abgebrochen / 9078 [Nachricht] Software nicht als FinTS-Produkt registriert. Bitte an Hersteller wenden.")
        XCTAssertTrue(AppModel.isProductIDRejection(atruvia))
        XCTAssertTrue(AppModel.isProductIDRejection(CoreError.Bank(code: "9078", message: "x")))
        XCTAssertFalse(AppModel.isProductIDRejection(CoreError.Bank(code: "9931", message: "PIN falsch")))
        XCTAssertFalse(AppModel.isProductIDRejection(CoreError.Authentication(message: "9078")))
    }

    func testNoRegistrationMeansNoSourceUnlessBuiltIn() {
        XCTAssertEqual(model.fintsProductIDSource, model.fintsBuiltinAvailable ? "builtin" : "")
    }
}
