import SwiftUI
import XCTest
@testable import GiroCrabUI

@MainActor
final class AnimatedCrabLogoViewTests: XCTestCase {
    func testPhasesRenderNonEmptyImages() {
        for phase: AnimatedCrabLogoView.Phase in [.idle, .unlocking, .unlocked, .failed] {
            let r = ImageRenderer(content: AnimatedCrabLogoView(size: 120, phase: phase))
            XCTAssertNotNil(r.cgImage, "\(phase)")
        }
    }

    func testRendersWithoutBackground() {
        let r = ImageRenderer(content: AnimatedCrabLogoView(size: 64, phase: .idle, showBackgroundSquircle: false))
        XCTAssertEqual(r.cgImage?.width, 64 * Int(r.scale))
    }

    func testPhaseTransitionsAreDistinctAndEquatable() {
        var view = AnimatedCrabLogoView(size: 120)
        XCTAssertEqual(view.phase, .idle)
        view.phase = .unlocking
        XCTAssertNotEqual(view.phase, .idle)
        view.phase = .unlocked
        XCTAssertEqual(view.phase, .unlocked)
    }

    /// The idle wave is time-driven (no `onAppear` needed), moves, and stays subtle.
    func testIdleWaveMovesOverTimeWithinBounds() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let samples = stride(from: 0.0, to: 6.0, by: 0.1).map { AnimatedCrabLogoView.idleWave(at: start.addingTimeInterval($0)) }
        XCTAssertGreaterThan(Set(samples.map { Int(($0.claw * 10).rounded()) }).count, 10)
        XCTAssertGreaterThan(Set(samples.map { Int(($0.card * 10).rounded()) }).count, 10)
        XCTAssertTrue(samples.allSatisfy { abs($0.claw) <= 5 && abs($0.card) <= 3.5 })
    }
}
