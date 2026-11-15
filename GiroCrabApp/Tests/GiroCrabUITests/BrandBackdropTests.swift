import SwiftUI
import XCTest
@testable import GiroCrabUI

/// Start and lock screen on the brand backdrop (iOS, GitHub #505).
@MainActor
final class BrandBackdropTests: XCTestCase {
    private var assets: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Xcode/App/Assets.xcassets")
    }

    private func png(_ view: some View, scale: CGFloat) throws -> (data: Data, width: Int, height: Int) {
        let r = ImageRenderer(content: view)
        r.scale = scale
        r.isOpaque = false
        let image = try XCTUnwrap(r.cgImage)
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return (data as Data, image.width, image.height)
    }

    /// The system launch screen shows the same backdrop in light and dark mode: no white flash.
    func testLaunchBackgroundIsTheBrandBackdropInBothAppearances() throws {
        let data = try Data(contentsOf: assets.appendingPathComponent("LaunchBackground.colorset/Contents.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let colors = try XCTUnwrap(json["colors"] as? [[String: Any]])
        XCTAssertFalse(colors.isEmpty)
        for entry in colors {
            let c = try XCTUnwrap((entry["color"] as? [String: Any])?["components"] as? [String: String])
            XCTAssertEqual([c["red"], c["green"], c["blue"]], ["0x1C", "0x23", "0x31"])
        }
    }

    /// The launch image is the start screen's logo: same artwork size, so the hand-off has no jump.
    func testLaunchLogoMatchesTheStartLogo() throws {
        let points = Int(BrandBackdrop.logoSize * BrandCrabLogo.glowFactor)
        for scale in 1...3 {
            let url = assets.appendingPathComponent("LaunchLogo.imageset/launch-logo@\(scale)x.png")
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, points * scale)
            XCTAssertEqual(image.height, points * scale)
            // transparent corners: no box around the crab
            XCTAssertNotEqual(image.alphaInfo, .none)
        }
    }

    func testBrandScreensRender() throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        let size = CGSize(width: 393, height: 852)
        let lock = LockView(brand: true).environment(model).frame(width: size.width, height: size.height)
        let splash = SplashView(brand: true).frame(width: size.width, height: size.height)
        let out = ProcessInfo.processInfo.environment["GIROCRAB_BRAND_PREVIEW_DIR"]
        for (name, view) in [("lock", AnyView(lock)), ("splash", AnyView(splash))] {
            let image = try png(view, scale: 2)
            XCTAssertEqual(image.width, Int(size.width) * 2)
            if let out { try image.data.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png")) }
        }
    }

    /// Regenerates `LaunchLogo` from the vector crab:
    /// `GIROCRAB_WRITE_LAUNCH_LOGO=1 swift test --filter BrandBackdropTests`.
    func testWriteLaunchLogo() throws {
        guard ProcessInfo.processInfo.environment["GIROCRAB_WRITE_LAUNCH_LOGO"] == "1" else {
            throw XCTSkip("Set GIROCRAB_WRITE_LAUNCH_LOGO=1 to rewrite the launch image")
        }
        for scale in 1...3 {
            let image = try png(BrandCrabLogo(), scale: CGFloat(scale))
            try image.data.write(to: assets.appendingPathComponent("LaunchLogo.imageset/launch-logo@\(scale)x.png"))
        }
    }
}
