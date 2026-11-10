import SwiftUI

extension View {
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
