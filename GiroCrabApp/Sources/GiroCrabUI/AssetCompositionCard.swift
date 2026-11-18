import SwiftUI
import GiroCrabCore

/// A collapsible analysis card of a holdings view: a title with a chevron and a body that
/// folds away. Each analysis (composition, value history) is a card of its own, with its own
/// remembered state, so folding one never hides the other.
struct AssetSectionCard<Content: View>: View {
    let title: LocalizedStringKey
    @AppStorage private var expanded: Bool
    let content: () -> Content

    init(title: LocalizedStringKey, expandedKey: String, defaultExpanded: Bool = true,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self._expanded = AppStorage(wrappedValue: defaultExpanded, expandedKey)
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(Motion.animation(.easeInOut(duration: 0.2))) { expanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: "chevron.right").appFont(.caption, weight: .semibold)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(title).appFont(.subheadline, weight: .semibold)
                    Spacer()
                }
                .foregroundStyle(Theme.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? Text("Ausgeklappt") : Text("Eingeklappt"))
            if expanded {
                content()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// "Zusammensetzung" of a holdings view from finished slices: the grouping control of the caller, the
/// drawing (ring, ranked bars or treemap) with one shared colour per slice, the click filter and the
/// notes below. The depot and Sachwerte cards (`AssetCompositionCard`) and the wealth tabs share it, so
/// every composition looks and behaves the same.
struct SliceCompositionCard<Grouping: View, Footer: View>: View {
    /// All slices of the grouping, largest first; folding for the drawing happens here.
    let slices: [DepotSlice]
    let currency: String
    /// Whether the position-like slices fold into "Weitere (n)" in the ring (not for classes).
    var foldsRing = true
    /// The positions behind the slice the user clicked: the list below shows only these (nil: all).
    @Binding var filter: Set<String>?
    let expandedKey: String
    /// Says what the composition covers where that is not obvious.
    var note: LocalizedStringKey?
    var emptyText: LocalizedStringKey = "Keine bewerteten Positionen"
    /// The grouping control; the argument says whether only the compact form (a menu) fits.
    @ViewBuilder var grouping: (Bool) -> Grouping
    @ViewBuilder var footer: () -> Footer
    @AppStorage private var displayRaw: String
    /// "Alle anzeigen": the "Weitere (n)" slice is unfolded into its positions.
    @State private var showAll = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.textScale) private var textScale
    @Environment(\.reportRedaction) private var redaction

    init(slices: [DepotSlice], currency: String, foldsRing: Bool = true, filter: Binding<Set<String>?>,
         expandedKey: String, displayKey: String, note: LocalizedStringKey? = nil,
         emptyText: LocalizedStringKey = "Keine bewerteten Positionen",
         @ViewBuilder grouping: @escaping (Bool) -> Grouping, @ViewBuilder footer: @escaping () -> Footer) {
        self.slices = slices
        self.currency = currency
        self.foldsRing = foldsRing
        self._filter = filter
        self.expandedKey = expandedKey
        self.note = note
        self.emptyText = emptyText
        self.grouping = grouping
        self.footer = footer
        self._displayRaw = AppStorage(wrappedValue: CompositionDisplay.ring.rawValue, displayKey)
    }

    private var display: Binding<CompositionDisplay> {
        Binding(get: { CompositionDisplay(rawValue: displayRaw) ?? .ring }, set: { displayRaw = $0.rawValue })
    }

    var body: some View {
        let all = slices
        let total = all.reduce(Int64(0)) { $0 + $1.cents }
        AssetSectionCard(title: "Zusammensetzung", expandedKey: expandedKey) {
            controls
            if let note {
                Text(note).appFont(.caption).foregroundStyle(Theme.secondary)
            }
            if total > 0 {
                let ring = CompositionDrawing.ringSlices(all, foldsRing: foldsRing, showAll: showAll)
                let tiles = CompositionDrawing.tileSlices(all, showAll: showAll)
                // the clicked slice, as long as it still exists in the drawing that shows it
                let selected = (display.wrappedValue == .tiles ? tiles : display.wrappedValue == .ring ? ring : all)
                    .first { filter != nil && $0.memberKeys == filter }?.id
                CompositionDrawing(display: display.wrappedValue, all: all, total: total, currency: currency,
                                   foldsRing: foldsRing, showAll: showAll, selected: selected, select: choose)
                if CompositionDrawing.isFolded(display.wrappedValue, all: all, foldsRing: foldsRing) || showAll {
                    Button { withAnimation(Motion.animation(.easeInOut(duration: 0.2))) { showAll.toggle() } } label: {
                        Label(showAll ? String(localized: "Weniger anzeigen") : String(localized: "Alle \(all.count) anzeigen"),
                              systemImage: showAll ? "chevron.up.circle" : "list.bullet")
                    }
                    .buttonStyle(.plain).appFont(.caption).foregroundStyle(Theme.accent)
                }
                if filter != nil {
                    Button { filter = nil } label: {
                        Label("Alle anzeigen", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).appFont(.caption).foregroundStyle(Theme.accent)
                }
            } else {
                Text(emptyText).appFont(.caption).foregroundStyle(Theme.secondary)
            }
            footer()
        }
    }

    /// A click on a slice filters the list to its positions; the same slice again, or "Alle anzeigen", ends it.
    private func choose(_ s: DepotSlice) {
        filter = filter == s.memberKeys ? nil : s.memberKeys
    }

    /// Grouping and drawing. iPhone: always the compact form, a menu plus icons; elsewhere side by side
    /// or stacked, and the compact form where even that does not fit.
    @ViewBuilder
    private var controls: some View {
        #if os(iOS)
        HStack(spacing: 10) { grouping(true); displayTools }
            .onChange(of: displayRaw) { filter = nil }
        #else
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { grouping(false); displayTools }
            VStack(alignment: .leading, spacing: 8) { grouping(false); displayTools }
            HStack(spacing: 10) { grouping(true); displayTools }
        }
        .onChange(of: displayRaw) { filter = nil }
        #endif
    }

    /// The display switch and the share button (the picture of what is shown, via the system share sheet).
    private var displayTools: some View {
        HStack(spacing: 10) {
            displayPicker
            shareButton
        }
    }

    @ViewBuilder
    private var shareButton: some View {
        let all = slices
        let total = all.reduce(Int64(0)) { $0 + $1.cents }
        if total > 0 {
            let drawing = CompositionDrawing(display: display.wrappedValue, all: all, total: total, currency: currency,
                                             foldsRing: foldsRing, showAll: showAll)
            let (scheme, scale, redaction) = (colorScheme, textScale, redaction)
            ShareLink(item: CompositionSnapshot(render: {
                CompositionSnapshot.png(of: drawing, scheme: scheme, textScale: scale, redaction: redaction)
            }), preview: SharePreview("Zusammensetzung")) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .help("Grafik als Bild teilen")
            .accessibilityLabel("Grafik als Bild teilen")
        }
    }

    /// Icons like the chart switch of the account header (#634): small segments, the name as help and
    /// VoiceOver label.
    private var displayPicker: some View {
        Picker("Darstellung", selection: display) {
            ForEach(CompositionDisplay.allCases) { d in
                Image(systemName: d.symbol)
                    .accessibilityLabel(d.title)
                    .help(d.title)
                    .tag(d)
            }
        }
        .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
        .help("Darstellung")
    }
}

/// "Zusammensetzung" of the depot and Sachwerte: the current inventory, grouped by position, asset
/// class or instrument. Unclassified items stay in the sum as their own grey slice; a search in the
/// list never changes the base.
struct AssetCompositionCard: View {
    let assets: [ClassifiedAsset]
    let currency: String
    /// The groupings on offer; with one entry there is no switch.
    let modes: [DepotCompositionMode]
    @Binding var mode: DepotCompositionMode
    @Binding var filter: Set<String>?
    let expandedKey: String
    let displayKey: String
    var note: LocalizedStringKey?

    init(assets: [ClassifiedAsset], currency: String, modes: [DepotCompositionMode] = DepotCompositionMode.allCases,
         mode: Binding<DepotCompositionMode>, filter: Binding<Set<String>?>, expandedKey: String, displayKey: String,
         note: LocalizedStringKey? = nil) {
        self.assets = assets
        self.currency = currency
        self.modes = modes
        self._mode = mode
        self._filter = filter
        self.expandedKey = expandedKey
        self.displayKey = displayKey
        self.note = note
    }

    var body: some View {
        let excluded = DepotComposition.excludedCount(assets)
        let unclassified = assets.filter { $0.classification.assetClass == .unclassified && $0.holding.valueCents > 0 }.count
        SliceCompositionCard(
            slices: DepotComposition.groups(assets, mode: mode), currency: currency, foldsRing: mode == .position,
            filter: $filter, expandedKey: expandedKey, displayKey: displayKey, note: note,
            grouping: { compact in
                if modes.count > 1 {
                    Picker("Gruppierung", selection: $mode) {
                        ForEach(modes) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().controlSize(.small).fixedSize()
                    .modifier(GroupingStyle(compact: compact))
                    .onChange(of: mode) { filter = nil }
                }
            },
            footer: {
                if excluded > 0 {
                    Text(excluded == 1
                         ? String(localized: "1 Position ohne positiven Wert ist nicht dargestellt und nicht in der Summe.")
                         : String(localized: "\(excluded) Positionen ohne positiven Wert sind nicht dargestellt und nicht in der Summe."))
                        .appFont(.caption).foregroundStyle(Theme.secondary)
                }
                if mode == .position, unclassified > 0 {
                    Text(unclassified == 1
                         ? String(localized: "1 Position ohne Klassifizierung – im Kontextmenü zuordnen.")
                         : String(localized: "\(unclassified) Positionen ohne Klassifizierung – im Kontextmenü einer Position zuordnen."))
                        .appFont(.caption).foregroundStyle(Theme.secondary)
                }
            })
    }
}

/// Segments where there is room, a menu where there is not.
struct GroupingStyle: ViewModifier {
    let compact: Bool
    func body(content: Content) -> some View {
        if compact { content.pickerStyle(.menu) } else { content.pickerStyle(.segmented) }
    }
}
