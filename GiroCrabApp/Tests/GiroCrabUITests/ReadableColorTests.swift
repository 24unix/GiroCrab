import XCTest
@testable import GiroCrabUI

/// `Color.readable` in the dark theme: dark category / brand colours are
/// lightened just enough for text contrast, keeping hue and saturation.
final class ReadableColorTests: XCTestCase {
    private func hue(_ hex: String) -> Double {
        let (r, g, b) = ReadableColor.rgb(hex)
        return ReadableColor.hsl(r, g, b).0
    }

    private func saturation(_ hex: String) -> Double {
        let (r, g, b) = ReadableColor.rgb(hex)
        return ReadableColor.hsl(r, g, b).1
    }

    func testDarkColoursReachTextContrastAndKeepTheirHue() {
        // MoneyMoney demo colours and a few dark brand colours
        for hex in ["1E7199", "1E2C99", "1E9991", "5856D6", "0A2540", "8B0000"] {
            for target in [4.5, 7.0] {
                let out = ReadableColor.onDark(hex: hex, minContrast: target)
                XCTAssertGreaterThanOrEqual(
                    ReadableColor.contrast(out, ReadableColor.darkSurface), target, "\(hex) → \(out)")
                XCTAssertEqual(hue(out), hue(hex), accuracy: 0.02, "hue of \(hex) → \(out)")
                // stays a colour, not grey (rounding to bytes moves saturation a little)
                XCTAssertGreaterThan(saturation(out), saturation(hex) * 0.8, "saturation of \(hex) → \(out)")
            }
        }
    }

    func testColoursWithEnoughContrastStayUnchanged() {
        for hex in ["FF9500", "34C759", "F1F5F9"] {
            XCTAssertEqual(ReadableColor.onDark(hex: hex, minContrast: 4.5), "#" + hex)
        }
    }

    func testOnlyAsMuchLighterAsNeeded() {
        // the muted blue from MoneyMoney must not end up near white
        let out = ReadableColor.onDark(hex: "1E7199", minContrast: 4.5)
        XCTAssertLessThan(ReadableColor.luminance(hex: out), 0.35, out)
    }

    func testBlackBecomesReadableGrey() {
        let out = ReadableColor.onDark(hex: "000000", minContrast: 4.5)
        XCTAssertGreaterThanOrEqual(ReadableColor.contrast(out, ReadableColor.darkSurface), 4.5)
        let (r, g, b) = ReadableColor.rgb(out)
        XCTAssertEqual(r, g); XCTAssertEqual(g, b)
    }

    func testHSLRoundTrip() {
        for hex in ["1E7199", "FF9500", "808080", "000000", "FFFFFF"] {
            let (r, g, b) = ReadableColor.rgb(hex)
            let (h, s, l) = ReadableColor.hsl(r, g, b)
            let c = ReadableColor.rgbFromHSL(h, s, l)
            XCTAssertEqual(ReadableColor.hexString(c.0, c.1, c.2), "#" + hex)
        }
    }
}
