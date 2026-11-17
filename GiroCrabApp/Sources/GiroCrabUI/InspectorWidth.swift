import CoreGraphics

/// Width rules of the draggable macOS detail column (#828). `width` is kept in
/// unscaled points; the column is drawn `width * textScale` wide (#343).
enum InspectorWidth {
    static let minimum: CGFloat = 280
    static let maximum: CGFloat = 380
    static let standard: CGFloat = 320

    /// Width after dragging the splitter `translation` points to the right, starting at
    /// `start`. The pointer moves in screen points, the column grows by `textScale` per
    /// unscaled point, so the translation is divided by it: the edge stays under the mouse.
    static func dragged(from start: CGFloat, translation: CGFloat, textScale: CGFloat) -> CGFloat {
        let scale = max(textScale, 0.1)
        return clamped(start - translation / scale)
    }

    static func clamped(_ width: CGFloat) -> CGFloat {
        min(maximum, max(minimum, width))
    }
}
