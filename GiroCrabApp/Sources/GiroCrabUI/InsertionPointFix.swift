import SwiftUI

#if os(macOS)
import AppKit

/// Dark Mode: in password fields inside sheets the shared field editor can keep a dark insertion
/// point (the caret is invisible on the dark field, #321). Pin it to the dynamic label colour,
/// which AppKit resolves against the field's current appearance.
private struct InsertionPointFix: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            apply()
        }
        func apply() {
            guard let window, let editor = window.fieldEditor(true, for: nil) as? NSTextView else { return }
            editor.insertionPointColor = .labelColor
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) { nsView.apply() }
}

extension View {
    /// Keeps the text cursor visible in Dark Mode. No-op on iOS.
    func visibleInsertionPoint() -> some View {
        background(InsertionPointFix().frame(width: 0, height: 0).accessibilityHidden(true))
    }
}
#else
extension View {
    func visibleInsertionPoint() -> some View { self }
}
#endif
