import XCTest
import SwiftUI
import GiroCrabCore
@testable import GiroCrabUI

/// "Logos aus dem Internet laden: Aus" shows no favicons, not even ones cached earlier (#422).
@MainActor
final class MerchantLogoOffTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
    }

    override func tearDown() async throws { model = nil }

    func testCachedLogoIsHiddenWhileOnlineLogosAreOff() async throws {
        let merchant = try XCTUnwrap(model.bookings.map(\.merchant).first { !$0.domainCandidates.isEmpty })
        model.logoCache[merchant.domainCandidates.joined(separator: "|")] = (image: Image(systemName: "cart"), pixels: 128)

        model.logoProvider = "off"
        XCTAssertNil(model.cachedLogo(for: merchant))
        let whileOff = await model.logo(for: merchant)
        XCTAssertNil(whileOff)

        // Switching back on shows the cached logo again without a new download.
        model.logoProvider = "duckduckgo"
        XCTAssertEqual(model.cachedLogo(for: merchant)?.pixels, 128)
        let whileOn = await model.logo(for: merchant)
        XCTAssertEqual(whileOn?.pixels, 128)
    }

    /// Signets rerun when `logoProvider` changes and the core gates cached logos on
    /// the stored setting: the switch must reach the UI only once the core has it.
    func testProviderSwitchIsPublishedAfterTheCoreStoredIt() async throws {
        let vault = try XCTUnwrap(model.vault)
        XCTAssertEqual(model.logoProvider, "off")
        model.saveSettingInBackground("merchants.online_logos", "duckduckgo")
        XCTAssertEqual(model.logoProvider, "off", "not yet stored in the core")
        await model.settingsWriteTask?.value
        XCTAssertEqual(try vault.onlineLogoProvider(), "duckduckgo")
        XCTAssertEqual(model.logoProvider, "duckduckgo")
    }
}
