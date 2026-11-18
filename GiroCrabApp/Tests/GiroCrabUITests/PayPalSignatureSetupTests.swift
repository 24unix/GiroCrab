import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// PayPal via API signature (classic NVP API, #752): the setup is complete only
/// with all three fields, and the secrets are entered masked.
@MainActor
final class PayPalSignatureSetupTests: XCTestCase {
    private var model: AppModel!
    private let connection = BankConnection(
        id: 1, connector: .payPal, displayName: "PayPal", loginName: "paypal-test", bankCode: "",
        sfSymbol: "p.circle", lastSyncUnix: nil, allAccountsArchived: false)

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
    }

    override func tearDown() async throws { model = nil }

    func testWithoutSignatureTheRestAppIsRequired() {
        XCTAssertFalse(model.payPalUsesSignature)
        let missing = model.missingSettings(for: connection)
        XCTAssertTrue(missing.contains("paypal.client_id"), "\(missing)")
        XCTAssertFalse(missing.contains("paypal.api_signature"), "\(missing)")
    }

    func testASignatureAloneIsNotComplete() {
        model.saveSetting("paypal.api_signature", "fiktive-signatur")
        XCTAssertTrue(model.payPalUsesSignature)
        XCTAssertEqual(model.missingSettings(for: connection), ["paypal.api_username", "paypal.api_password"])
    }

    func testAllThreeFieldsComplete() {
        model.saveSetting("paypal.api_username", "api1.example")
        XCTAssertEqual(model.missingSettings(for: connection), ["paypal.api_password", "paypal.api_signature"])
        model.saveSetting("paypal.api_password", "fiktives-passwort")
        model.saveSetting("paypal.api_signature", "fiktive-signatur")
        XCTAssertEqual(model.missingSettings(for: connection), [])
    }

    func testPasswordAndSignatureAreEnteredMasked() {
        for key in ["paypal.api_password", "paypal.api_signature"] {
            XCTAssertTrue(AppModel.isSecretSetting(key, model.settingEntry(key)), key)
            XCTAssertTrue(AppModel.isSecretSetting(key, nil), "\(key) before the settings are loaded")
        }
        XCTAssertFalse(AppModel.isSecretSetting("paypal.api_username", model.settingEntry("paypal.api_username")))
    }
}
