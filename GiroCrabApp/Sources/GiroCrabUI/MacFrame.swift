import SwiftUI

extension View {
    /// Split-view column widths are desktop-only; on iOS the system sizes the columns.
    @ViewBuilder
    func macColumnWidth(min: CGFloat? = nil, ideal: CGFloat, max: CGFloat? = nil) -> some View {
        #if os(macOS)
        navigationSplitViewColumnWidth(min: min, ideal: ideal, max: max)
        #else
        self
        #endif
    }

    /// Fixed/min sizes are for macOS windows & sheets only; on iOS the sheet fills the screen.
    @ViewBuilder
    func macFrame(width: CGFloat? = nil, minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil,
                  minHeight: CGFloat? = nil, height: CGFloat? = nil) -> some View {
        #if os(macOS)
        frame(minWidth: minWidth, idealWidth: idealWidth, minHeight: minHeight)
            .frame(width: width, height: height)
        #else
        self
        #endif
    }
}
