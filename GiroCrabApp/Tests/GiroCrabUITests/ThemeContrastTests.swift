import XCTest
@testable import GiroCrabUI

/// WCAG AA audit (≥ 4.5:1) of the text colours in light, dark and both
/// "Kontrast erhöhen" variants (GitHub #571, #218).
final class ThemeContrastTests: XCTestCase {
    private let minimum = 4.5

    private func surface(_ s: (name: String, light: String, dark: String), variant: String) -> String {
        variant.hasPrefix("light") ? s.light : s.dark
    }

    private func assertText(_ name: String, _ spec: ThemeShade, file: StaticString = #filePath, line: UInt = #line) {
        for s in Theme.surfaceHex {
            for v in spec.variants {
                let ratio = ReadableColor.contrast(v.hex, surface(s, variant: v.name))
                XCTAssertGreaterThanOrEqual(ratio, minimum, "\(name) \(v.name) \(v.hex) on \(s.name): \(ratio)", file: file, line: line)
            }
        }
    }

    func testTextTokensReachAA() {
        for t in Theme.textSpecs { assertText(t.name, t.spec) }
    }

    func testBadgeTextReachesAA() {
        for p in Theme.badgePairs {
            for (t, b) in zip(p.text.variants, p.background.variants) {
                let ratio = ReadableColor.contrast(t.hex, b.hex)
                XCTAssertGreaterThanOrEqual(ratio, minimum, "\(p.name) \(t.name): \(ratio)")
            }
        }
    }

    func testAmountSchemesReachAA() {
        for style in NegativeAmountStyle.allCases {
            assertText("\(style.rawValue) negative", style.negativeSpec)
            assertText("\(style.rawValue) positive", style.positiveSpec)
            for (t, b) in zip(style.positiveSpec.variants, style.positiveBadgeSpec.variants) {
                let ratio = ReadableColor.contrast(t.hex, b.hex)
                XCTAssertGreaterThanOrEqual(ratio, minimum, "\(style.rawValue) badge \(t.name): \(ratio)")
            }
        }
    }

    func testHighContrastIsNotWeaker() {
        for t in Theme.textSpecs {
            for s in Theme.surfaceHex {
                let l = ReadableColor.contrast(t.spec.light, s.light)
                let lh = ReadableColor.contrast(t.spec.lightHighContrast ?? t.spec.light, s.light)
                XCTAssertGreaterThanOrEqual(lh, l - 0.001, "\(t.name) light HC on \(s.name)")
                let d = ReadableColor.contrast(t.spec.dark, s.dark)
                let dh = ReadableColor.contrast(t.spec.darkHighContrast ?? t.spec.dark, s.dark)
                XCTAssertGreaterThanOrEqual(dh, d - 0.001, "\(t.name) dark HC on \(s.name)")
            }
        }
    }
}
