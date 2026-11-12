// Entry point of the Xcode multiplatform target (iOS 17+ / macOS 14+).
// All UI lives in the GiroCrabUI library (../Sources/GiroCrabUI).
//
// Demo mode: run the "GiroCrab (Demo)" scheme, which sets GIROCRAB_DEMO_SEED=1.
import SwiftUI
import GiroCrabUI

@main
struct GiroCrabApp: App {
    // The model is built here, once and outside the body's dependency tracking
    // (see GiroCrabScenes.prepare).
    init() { GiroCrabScenes.prepare() }

    var body: some Scene {
        GiroCrabScenes()
    }
}
