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
    /// They grow with the text size (#343), like the text in them.
    @ViewBuilder
    func macFrame(width: CGFloat? = nil, minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil,
                  minHeight: CGFloat? = nil, height: CGFloat? = nil) -> some View {
        #if os(macOS)
        modifier(MacFrame(width: width, minWidth: minWidth, idealWidth: idealWidth, minHeight: minHeight, height: height))
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct MacFrame: ViewModifier {
    @Environment(\.textScale) private var scale
    let width, minWidth, idealWidth, minHeight, height: CGFloat?

    func body(content: Content) -> some View {
        content
            .frame(minWidth: minWidth.map { $0 * scale }, idealWidth: idealWidth.map { $0 * scale },
                   minHeight: minHeight.map { $0 * scale })
            .frame(width: width.map { $0 * scale }, height: height.map { $0 * scale })
    }
}
#endif

/// Heights for sizing a macOS sheet to its scrolling form (#879): the form's
/// content and visible height, and the whole sheet's height.
struct FormFit: Equatable {
    var content: CGFloat = 0
    var container: CGFloat = 0
    var total: CGFloat = 0

    /// Sheet height that shows the whole form without scrolling, within
    /// `min`…`max`; `nil` until the form was measured. The rest of the sheet
    /// (`total - container`) keeps its height.
    func height(min: CGFloat, max: CGFloat) -> CGFloat? {
        guard content > 0, container > 0, total > 0 else { return nil }
        return Swift.min(Swift.max(total - container + content, min), max)
    }
}

extension View {
    /// Reports a scrolling form's content and visible height into `fit`.
    /// Needs macOS 15; before that the sheet keeps its fixed height.
    @ViewBuilder
    func reportsFormFit(_ fit: Binding<FormFit>) -> some View {
        #if os(macOS)
        if #available(macOS 15, *) {
            onScrollGeometryChange(for: [CGFloat].self) { g in
                [g.contentSize.height + g.contentInsets.top + g.contentInsets.bottom, g.containerSize.height]
            } action: { _, h in
                fit.wrappedValue.content = h[0]
                fit.wrappedValue.container = h[1]
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}
