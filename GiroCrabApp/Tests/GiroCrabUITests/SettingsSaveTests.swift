import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// Settings edited in the Settings window are written off the main thread.
@MainActor
final class SettingsSaveTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
        XCTAssertNil(model.errorMessage)
    }

    override func tearDown() async throws { model = nil }

    private func awaitProvider(_ expected: String) async {
        for _ in 0..<300 {
            if model.logoProvider == expected { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The background save did not publish logo provider \(expected)")
    }

    func testBackgroundSaveReachesVaultAndPublishes() async throws {
        model.saveSettingInBackground("merchants.online_logos", "duckduckgo")
        await awaitProvider("duckduckgo")
        XCTAssertEqual(try XCTUnwrap(model.vault).onlineLogoProvider(), "duckduckgo")
        XCTAssertNil(model.errorMessage)
    }

    func testQuickEditsKeepTheirOrder() async throws {
        model.saveSettingInBackground("merchants.online_logos", "google")
        model.saveSettingInBackground("merchants.online_logos", "off")
        model.saveSettingInBackground("merchants.online_logos", "duckduckgo")
        await awaitProvider("duckduckgo")
        // let a possibly out-of-order earlier write finish, then check the final state
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(try XCTUnwrap(model.vault).onlineLogoProvider(), "duckduckgo")
        XCTAssertEqual(model.logoProvider, "duckduckgo")
    }

    #if os(macOS)
    func testDocumentFolderIsCreatedOffMainAndSwitchOffClears() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("girocrab-mirror-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: url) }
        model.setDocumentMirror(url)
        XCTAssertEqual(model.documentMirrorPath, url.path)  // the switch reacts at once
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: url.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(model.errorMessage)
        model.setDocumentMirror(nil)
        XCTAssertNil(model.documentMirrorPath)
    }
    #endif
}
