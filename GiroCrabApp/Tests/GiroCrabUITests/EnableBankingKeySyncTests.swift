import XCTest
@testable import GiroCrabUI

/// The Enable Banking application (ID + key) via the iCloud Keychain: which
/// side wins when a vault opens (`EnableBankingKeySync.reconcile`).
final class EnableBankingKeySyncTests: XCTestCase {
    private let a = EnableBankingApp(applicationID: "app-1", pem: "KEY-A")
    private let b = EnableBankingApp(applicationID: "app-2", pem: "KEY-B")

    func testVaultEmptyStoreHasAdopts() {
        XCTAssertEqual(EnableBankingKeySync.reconcile(vault: nil, store: a), .adopt(a))
    }

    func testStoreEmptyVaultHasUploads() {
        XCTAssertEqual(EnableBankingKeySync.reconcile(vault: a, store: nil), .upload(a))
    }

    func testBothEqualDoesNothing() {
        XCTAssertEqual(EnableBankingKeySync.reconcile(vault: a, store: a), .none)
    }

    func testBothDifferentAdoptsStore() {
        // the store holds the key saved last on any device
        XCTAssertEqual(EnableBankingKeySync.reconcile(vault: a, store: b), .adopt(b))
    }

    func testBothEmptyDoesNothing() {
        XCTAssertEqual(EnableBankingKeySync.reconcile(vault: nil, store: nil), .none)
    }

    func testIncompleteAppCountsAsAbsent() {
        let noKey = EnableBankingApp(applicationID: "app-1", pem: "  ")
        let noID = EnableBankingApp(applicationID: "", pem: "KEY-A")
        XCTAssertEqual(EnableBankingKeySync.reconcile(vault: noKey, store: a), .adopt(a))
        XCTAssertEqual(EnableBankingKeySync.reconcile(vault: a, store: noID), .upload(a))
        XCTAssertEqual(EnableBankingKeySync.reconcile(vault: noKey, store: noID), .none)
    }

    /// The demo vault never shares (or takes over) a key, even with the opt-in on.
    @MainActor
    func testDemoVaultNeverUploads() throws {
        final class Recorder: EnableBankingKeyStore {
            var saved: [EnableBankingApp] = []
            func load() -> EnableBankingApp? { nil }
            func save(_ app: EnableBankingApp) throws { saved.append(app) }
        }
        let wasOn = VaultKeyManager.shared.syncViaICloudKeychain
        VaultKeyManager.shared.syncViaICloudKeychain = true
        defer { VaultKeyManager.shared.syncViaICloudKeychain = wasOn }
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertTrue(model.isDemo)
        let store = Recorder()
        model.enableBankingKeyStore = store
        model.saveSetting("enablebanking.application_id", "app-1")
        model.saveSetting("enablebanking.private_key_pem", "KEY-A")
        XCTAssertTrue(store.saved.isEmpty)
    }

    func testWhitespaceDoesNotTriggerAdopt() {
        let padded = EnableBankingApp(applicationID: " app-1 ", pem: "KEY-A\n")
        XCTAssertEqual(EnableBankingKeySync.reconcile(vault: a, store: padded), .none)
    }

    func testNoticeShortensApplicationIDAndNamesItsBanks() {
        let app = EnableBankingApp(applicationID: "0f3c9a71-2b4e-4d1a-9c55-7e8f00a1b2c3", pem: "KEY-A")
        let notice = EnableBankingKeySync.notice(for: app, replaced: false, banks: ["Finom", "N26"])
        XCTAssertEqual(notice.shortApplicationID, "0f3c9a71…")
        XCTAssertEqual(notice.banks, ["Finom", "N26"])
        XCTAssertFalse(notice.replaced)
        XCTAssertFalse(notice.message.contains("KEY-A"))
        XCTAssertTrue(notice.message.contains("0f3c9a71…"))
        XCTAssertTrue(notice.message.contains("Finom, N26"))
    }

    func testNoticeSaysWhenItReplacedAnotherApplication() {
        let replaced = EnableBankingKeySync.notice(for: a, replaced: true, banks: [])
        let filled = EnableBankingKeySync.notice(for: a, replaced: false, banks: [])
        XCTAssertNotEqual(replaced.message, filled.message)
    }

    func testShortIDKeepsShortIDsWhole() {
        let notice = EnableBankingKeySync.notice(for: EnableBankingApp(applicationID: " app-1 ", pem: "K"), replaced: false, banks: [])
        XCTAssertEqual(notice.shortApplicationID, "app-1")
    }
}
