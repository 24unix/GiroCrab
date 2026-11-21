import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// Einstellungen › Händler (#1373): a change reaches the booking list in the background; what
/// counts as consumption or investment and the recurring series stay as they were.
@MainActor
final class MerchantRecognitionTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
        XCTAssertNil(model.errorMessage)
    }

    override func tearDown() async throws { model = nil }

    /// Waits for the background reload to publish bookings that pass `done`.
    private func awaitBookings(_ done: ([Booking]) -> Bool,
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<2500 {
            if done(model.bookings) { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("the background reload did not publish the changed merchants", file: file, line: line)
    }

    /// A demo booking of a bundled supermarket or streaming brand.
    private func brandBooking() throws -> Booking {
        try XCTUnwrap(model.bookings.first { ["rewe", "lidl", "edeka", "netflix"].contains($0.merchant.key) })
    }

    func testRecognitionOffShowsTheCounterpartyAndKeepsTheAnalysis() async throws {
        let brand = try brandBooking()
        let consumption = model.selectionFlow?.consumption
        XCTAssertTrue(model.merchantRecognitionEnabled)

        let revision = model.merchantSettingsRevision
        try await model.setMerchantRecognitionEnabled(false)
        XCTAssertFalse(model.merchantRecognitionEnabled, "the inspector hides the logo domain at once")
        XCTAssertGreaterThan(model.merchantSettingsRevision, revision, "the settings list reads again")
        try await awaitBookings { $0.allSatisfy { !$0.merchant.known } }
        let off = try XCTUnwrap(model.bookings.first { $0.id == brand.id })
        XCTAssertTrue(off.merchant.key.hasPrefix("x:"), off.merchant.key)
        XCTAssertTrue(off.merchant.svgPath.isEmpty)
        XCTAssertTrue(off.merchant.domainCandidates.isEmpty)
        XCTAssertNil(off.merchantDomain)
        XCTAssertEqual(off.flow, brand.flow)
        XCTAssertEqual(off.recurrenceKey, brand.recurrenceKey)
        XCTAssertEqual(model.selectionFlow?.consumption, consumption)
        XCTAssertNil(model.errorMessage)

        try await model.setMerchantRecognitionEnabled(true)
        XCTAssertTrue(model.merchantRecognitionEnabled)
        try await awaitBookings { $0.contains { $0.id == brand.id && $0.merchant.key == brand.merchant.key } }
    }

    func testACopyReplacesTheOriginalAndDeletingItBringsTheOriginalBack() async throws {
        let brand = try brandBooking()
        let before = try await model.merchantRecognition()
        let original = try XCTUnwrap(before?.builtin.first { $0.key == brand.merchant.key })
        XCTAssertTrue(original.enabled)

        try await model.saveCustomMerchant(uuid: nil, name: "Eckladen", needles: original.needles, basedOn: original.key)
        try await awaitBookings { $0.contains { $0.id == brand.id && $0.merchantName == "Eckladen" } }
        let shown = try XCTUnwrap(model.bookings.first { $0.id == brand.id })
        XCTAssertTrue(shown.merchant.key.hasPrefix("u:"), shown.merchant.key)
        XCTAssertEqual(shown.merchant.svgPath, brand.merchant.svgPath, "the copy keeps the logo")
        XCTAssertEqual(shown.merchant.colorHex, brand.merchant.colorHex)
        XCTAssertEqual(shown.flow, brand.flow)
        XCTAssertEqual(shown.recurrenceKey, brand.recurrenceKey)
        let loaded = try await model.merchantRecognition()
        let after = try XCTUnwrap(loaded)
        let replaced = try XCTUnwrap(after.builtin.first { $0.key == original.key })
        XCTAssertTrue(replaced.replaced, "the copy replaces the original")
        XCTAssertTrue(replaced.enabled, "without touching its switch")
        let copy = try XCTUnwrap(after.custom.first)
        XCTAssertEqual(copy.basedOn, original.key)
        XCTAssertEqual(copy.merchant.key, shown.merchant.key)

        try await model.deleteCustomMerchant(copy.uuid)
        try await awaitBookings { $0.contains { $0.id == brand.id && $0.merchant.key == brand.merchant.key } }
        let reloaded = try await model.merchantRecognition()
        let restored = try XCTUnwrap(reloaded)
        XCTAssertEqual(restored.builtin.first { $0.key == original.key }?.replaced, false)
        XCTAssertEqual(restored.builtin.first { $0.key == original.key }?.enabled, true)
        XCTAssertTrue(restored.custom.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testSwitchingABundledMerchantOffAndOn() async throws {
        let brand = try brandBooking()
        try await model.setBuiltinMerchantEnabled(brand.merchant.key, false)
        try await awaitBookings { $0.contains { $0.id == brand.id && $0.merchant.key != brand.merchant.key } }
        let off = try await model.merchantRecognition()
        XCTAssertEqual(off?.builtin.first { $0.key == brand.merchant.key }?.enabled, false)
        try await model.setBuiltinMerchantEnabled(brand.merchant.key, true)
        try await awaitBookings { $0.contains { $0.id == brand.id && $0.merchant.key == brand.merchant.key } }
    }

    /// The editor shows the core's message itself: no alert, nothing stored.
    func testAnInvalidMerchantThrowsWithoutAnAlert() async throws {
        do {
            try await model.saveCustomMerchant(uuid: nil, name: "  ", needles: ["muster"], basedOn: nil)
            XCTFail("a merchant without a name was stored")
        } catch {}
        do {
            try await model.saveCustomMerchant(uuid: nil, name: "Laden", needles: ["- / *"], basedOn: nil)
            XCTFail("a merchant without a usable search word was stored")
        } catch {}
        XCTAssertNil(model.errorMessage)
        let stored = try await model.merchantRecognition()
        XCTAssertEqual(stored?.custom.isEmpty, true)
    }

    /// The settings pane shows the message itself: an alert of the main window would hide
    /// behind the Settings window.
    func testAFailedSwitchThrowsWithoutAnAlert() async throws {
        do {
            try await model.setBuiltinMerchantEnabled("gibt-es-nicht", false)
            XCTFail("an unknown merchant was switched")
        } catch {}
        XCTAssertNil(model.errorMessage)
    }

    /// A merchant filter that names nobody after a change (a copy has its own key, the
    /// recognition off gives `x:` keys) is left; one that still names bookings stays.
    func testAChangeLeavesAMerchantFilterThatNamesNobody() async throws {
        let brand = try brandBooking()
        let other = try XCTUnwrap(model.bookings.first { $0.merchant.known && $0.merchant.key != brand.merchant.key })
        model.focusMerchant(of: brand)
        XCTAssertEqual(model.merchantFocus?.key, brand.merchant.key)
        try await model.setBuiltinMerchantEnabled(other.merchant.key, false)
        try await awaitBookings { _ in model.selectionLoadTask == nil }
        XCTAssertEqual(model.merchantFocus?.key, brand.merchant.key, "its merchant is still there")
        try await model.setMerchantRecognitionEnabled(false)
        for _ in 0..<2500 where model.merchantFocus != nil { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertNil(model.merchantFocus)
    }

    /// The booking search finds the name the user gave a merchant (it is in no booking text).
    func testTheSearchFindsAnOwnMerchantName() async throws {
        let brand = try brandBooking()
        let loaded = try await model.merchantRecognition()
        let original = try XCTUnwrap(loaded?.builtin.first { $0.key == brand.merchant.key })
        try await model.saveCustomMerchant(uuid: nil, name: "Supermarkt Ecke", needles: original.needles, basedOn: original.key)
        let vault = try XCTUnwrap(model.vault)
        let found = try vault.listTransactions(filter: BookingFilter(
            accountIds: [], categoryId: nil, includeSubcategories: true, uncategorizedOnly: false,
            search: "Supermarkt Ecke", dateFrom: nil, dateTo: nil, limit: 0, offset: 0,
            scope: .all, merchantKey: nil, direction: .all, checked: nil, wholeDays: false
        )).transactions
        XCTAssertTrue(found.contains { $0.id == brand.id })
        XCTAssertTrue(found.allSatisfy { $0.merchantName == "Supermarkt Ecke" })
    }

    /// Quick toggles reach the vault in the order they were made.
    func testQuickTogglesKeepTheirOrder() async throws {
        let key = try brandBooking().merchant.key
        // each call queues its write before its first suspension, in call order
        let first = Task { try await model.setBuiltinMerchantEnabled(key, false) }
        let second = Task { try await model.setBuiltinMerchantEnabled(key, true) }
        let third = Task { try await model.setBuiltinMerchantEnabled(key, false) }
        for task in [first, second, third] { try await task.value }
        let loaded = try await model.merchantRecognition()
        XCTAssertEqual(loaded?.builtin.first { $0.key == key }?.enabled, false)
    }

    func testSearchWordsAreSplitAtCommasAndLineBreaks() {
        XCTAssertEqual(AppModel.merchantNeedles(" muster gmbh, muster shop;\nmuster-laden ,, "),
                       ["muster gmbh", "muster shop", "muster-laden"])
        XCTAssertEqual(AppModel.merchantNeedles(AppModel.merchantNeedlesText(["a b", "c"])), ["a b", "c"])
        XCTAssertEqual(AppModel.merchantNeedles(" , \n"), [])
    }

    func testTheLogoSettingsOpenOnTheMerchantsTab() {
        XCTAssertEqual(SettingsTab(demoName: "merchants"), .merchants)
        XCTAssertEqual(SettingsTab(demoName: "logos"), .merchants)
    }
}
