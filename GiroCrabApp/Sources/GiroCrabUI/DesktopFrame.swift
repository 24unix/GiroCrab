import SwiftUI

extension View {
    /// macOS: fixed/minimum sheet size for desktop windows. iOS: no-op, the sheet
    /// fills the viewport (a 480-pt frame would be clipped on a 375–430 pt iPhone).
    @ViewBuilder
    func desktopFrame(
        minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil, maxWidth: CGFloat? = nil,
        minHeight: CGFloat? = nil, idealHeight: CGFloat? = nil, maxHeight: CGFloat? = nil
    ) -> some View {
        #if os(macOS)
        frame(minWidth: minWidth, idealWidth: idealWidth, maxWidth: maxWidth,
              minHeight: minHeight, idealHeight: idealHeight, maxHeight: maxHeight)
        #else
        self
        #endif
    }

    /// macOS: exact size. iOS: no-op.
    @ViewBuilder
    func desktopFrame(width: CGFloat, height: CGFloat? = nil) -> some View {
        #if os(macOS)
        frame(width: width, height: height)
        #else
        self
        #endif
    }
}
