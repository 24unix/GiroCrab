#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import GiroCrabUI

/// The key dialog is a sheet over Settings, which is already a sheet (#768).
@MainActor
final class KeyPastePresentationTests: XCTestCase {
    @Observable fileprivate final class Presentation {
        var settings = false
        var keySheet = false
    }

    fileprivate struct Host: View {
        @Bindable var presentation: Presentation
        let model: AppModel

        var body: some View {
            Text("Settings presentation test")
                .capturableSheet(isPresented: $presentation.settings) {
                    NavigationStack { SecuritySettings(showKeySheet: $presentation.keySheet) }
                        .environment(model)
                }
        }
    }

    func testKeySheetStaysAboveSettingsAndDismissesIndependently() async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("Sheet presentation needs an app-hosted iOS test runner")
        }
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        let presentation = Presentation()
        let root = UIHostingController(rootView: Host(presentation: presentation, model: model))
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            root.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }

        try await Task.sleep(for: .milliseconds(300))
        presentation.settings = true
        try await Task.sleep(for: .seconds(1))
        let settings = try XCTUnwrap(root.presentedViewController)
        presentation.keySheet = true
        // Let SwiftUI mount the Form and finish the nested presentation.
        try await Task.sleep(for: .seconds(1))
        let keySheet = try XCTUnwrap(settings.presentedViewController)
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(root.presentedViewController === settings)
        XCTAssertTrue(settings.presentedViewController === keySheet)
        XCTAssertFalse(settings.isBeingDismissed)

        keySheet.dismiss(animated: false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(settings.presentedViewController)
        XCTAssertFalse(presentation.keySheet)
        XCTAssertTrue(presentation.settings)
        XCTAssertTrue(root.presentedViewController === settings)
        XCTAssertEqual(model.vaultState, .open)
        XCTAssertTrue(model.demoActive)
    }
}
#endif
