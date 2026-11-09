// macOS entry point for `swift run GiroCrabMac` / `cargo run` (the Xcode
// multiplatform target uses Xcode/App/GiroCrabApp.swift instead).
//
//   GiroCrabMac --demo-seed                 explore with demo data
//   GiroCrabMac --screenshot out.png        render the window to a PNG and quit
import AppKit
import SwiftUI
import GiroCrabUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let icon = Self.appIcon() {
            NSApp.applicationIconImage = icon
        }
        // In --screenshot mode don't steal the keyboard focus from the user.
        if LaunchOptions.current.screenshotPath == nil {
            NSApp.activate(ignoringOtherApps: true)
        }
        MainActor.assumeIsolated {
            WindowScreenshot.scheduleIfRequested()
        }
    }

    /// The GiroCrab icon, also when started outside an .app bundle
    /// (`swift run`, `cargo run`): bundle icns → asset catalog → source PNG.
    static func appIcon() -> NSImage? {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let img = NSImage(contentsOf: url) {
            return img
        }
        if let img = NSImage(named: "AppIcon") {
            return img
        }
        // .build/<config>/GiroCrabMac -> GiroCrabApp/Xcode/App/Assets.xcassets/…
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Xcode/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
            if let img = NSImage(contentsOf: candidate) { return img }
            let nested = dir.appendingPathComponent("GiroCrabApp/Xcode/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
            if let img = NSImage(contentsOf: nested) { return img }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct GiroCrabMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        GiroCrabScenes()
    }
}

GiroCrabMacApp.main()
