import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The drawing of a composition (ring, ranked bars or treemap) from finished slices: the card
/// shows it live, the shared picture draws the very same thing. `showAll` unfolds the "Weitere (n)"
/// slice, so every position has its own entry.
struct CompositionDrawing: View {
    let display: CompositionDisplay
    /// All slices of the grouping, largest first.
    let all: [DepotSlice]
    let total: Int64
    let currency: String
    var foldsRing = true
    var showAll = false
    var selected: String?
    var select: ((DepotSlice) -> Void)?
    /// The treemap's height where its width is not measured (the shared picture).
    var tileHeight: CGFloat?

    /// The slices of the ring and of the tiles (folded unless `showAll`).
    static func ringSlices(_ all: [DepotSlice], foldsRing: Bool, showAll: Bool) -> [DepotSlice] {
        foldsRing && !showAll ? DepotComposition.fold(all, keep: DepotComposition.maxPositionSlices) : all
    }

    static func tileSlices(_ all: [DepotSlice], showAll: Bool) -> [DepotSlice] {
        showAll ? all : DepotComposition.fold(all, keep: DepotComposition.maxTiles)
    }

    /// Whether this display folds something away that "Alle anzeigen" would bring back.
    static func isFolded(_ display: CompositionDisplay, all: [DepotSlice], foldsRing: Bool) -> Bool {
        switch display {
        case .ring: foldsRing && DepotComposition.fold(all, keep: DepotComposition.maxPositionSlices).count != all.count
        case .bars: DepotComposition.fold(all, keep: DepotComposition.maxRankedSlices).count != all.count
        case .tiles: DepotComposition.fold(all, keep: DepotComposition.maxTiles).count != all.count
        }
    }

    var body: some View {
        switch display {
        case .ring:
            CompositionRing(slices: Self.ringSlices(all, foldsRing: foldsRing, showAll: showAll), total: total,
                            currency: currency, selected: selected, select: select)
        case .bars:
            CompositionRankBars(slices: all, total: total, currency: currency, selected: selected, select: select,
                                keep: showAll ? max(all.count, 1) : DepotComposition.maxRankedSlices)
        case .tiles:
            CompositionTreemap(slices: Self.tileSlices(all, showAll: showAll), total: total, currency: currency,
                               selected: selected, select: select, fixedHeight: tileHeight)
        }
    }
}

/// The picture that is shared: title and date, then the drawing with its amounts. It is drawn
/// outside the window, so it carries the window's look (appearance, text size, privacy mode) with it.
private struct CompositionShareImage: View {
    let drawing: CompositionDrawing
    @Environment(\.textScale) private var textScale

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Zusammensetzung").appFont(.headline, weight: .semibold)
                Spacer()
                Text(Date.now.formatted(date: .abbreviated, time: .omitted))
                    .appFont(.caption).foregroundStyle(Theme.secondary)
            }
            drawing
        }
        .padding(20)
        .frame(width: 640 * textScale, alignment: .leading)
        .background(Theme.card)
    }
}

/// What `ShareLink` hands to the system share sheet: a PNG that is only drawn when the user picks a
/// service, not on every refresh of the card.
struct CompositionSnapshot: Transferable, @unchecked Sendable {
    let render: @MainActor () -> Data?

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { snapshot in
            guard let data = await snapshot.render() else { throw CocoaError(.fileWriteUnknown) }
            return data
        }
    }

    /// PNG of `drawing` in the given look; nil when it cannot be drawn.
    @MainActor
    static func png(of drawing: CompositionDrawing, scheme: ColorScheme, textScale: CGFloat,
                    redaction: ReportRedaction) -> Data? {
        var drawing = drawing
        drawing.tileHeight = 210 * textScale
        let content = CompositionShareImage(drawing: drawing)
            .environment(\.colorScheme, scheme)
            .environment(\.textScale, textScale)
            .environment(\.reportRedaction, redaction)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        #if os(macOS)
        guard let tiff = renderer.nsImage?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
        #else
        return renderer.uiImage?.pngData()
        #endif
    }
}
