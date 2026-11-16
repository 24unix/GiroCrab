import SwiftUI
import GiroCrabCore

/// The depot's positions: a compact sortable table in wide windows, two-line rows in narrow ones
/// and on iOS. Shares are relative to the whole inventory (`DepotPosition.share`), so a search
/// changes the rows but never the percentages.
///
/// One table for every holdings view (depot, Sachwerte account, wealth tabs). A view that lets rows be
/// selected or opened passes `onSelect` / `onOpen` and its own menu items; the pencil in each row
/// edits the classification wherever the position has one.
struct DepotPositionsTable<RowMenu: View>: View {
    @Environment(\.textScale) private var textScale
    let positions: [DepotPosition]
    /// Positions of the whole inventory (the rows shown may be a search result).
    let totalCount: Int
    @Binding var sort: DepotSort
    let wide: Bool
    let currency: String
    let onClassify: (ClassificationEditRequest) -> Void
    let copyAll: () -> Void
    /// Securities without a bank figure get one from the cost price: the table says so. Sachwerte
    /// work from their purchase data and turn the note off.
    var notesCalculatedGain = true
    var selectedID: String?
    var onSelect: ((DepotPosition) -> Void)?
    var onOpen: ((DepotPosition) -> Void)?
    let rowMenu: (DepotPosition) -> RowMenu
    @State private var expanded: Set<String> = []
    /// Which depot(s) hold a position, where the table spans several (Vermögen).
    private var depotLabelOf: ((DepotPosition) -> String?)?

    func depotLabel(_ label: @escaping (DepotPosition) -> String?) -> Self {
        var copy = self
        copy.depotLabelOf = label
        return copy
    }

    init(positions: [DepotPosition], totalCount: Int, sort: Binding<DepotSort>, wide: Bool, currency: String,
         onClassify: @escaping (ClassificationEditRequest) -> Void, copyAll: @escaping () -> Void,
         notesCalculatedGain: Bool = true, selectedID: String? = nil, onSelect: ((DepotPosition) -> Void)? = nil, onOpen: ((DepotPosition) -> Void)? = nil,
         @ViewBuilder rowMenu: @escaping (DepotPosition) -> RowMenu) {
        self.positions = positions
        self.totalCount = totalCount
        self._sort = sort
        self.wide = wide
        self.currency = currency
        self.onClassify = onClassify
        self.copyAll = copyAll
        self.notesCalculatedGain = notesCalculatedGain
        self.selectedID = selectedID
        self.onSelect = onSelect
        self.onOpen = onOpen
        self.rowMenu = rowMenu
    }

    private var anyCalculatedGain: Bool { positions.contains { $0.gain.map { !$0.reported } ?? false } }

    var body: some View {
        VStack(spacing: 0) {
            if wide { columnHeader } else { narrowHeader }
            Rectangle().fill(Theme.border).frame(height: 1)
            LazyVStack(spacing: 0) {
                ForEach(Array(positions.enumerated()), id: \.element.id) { i, p in
                    Group { wide ? AnyView(wideRow(p)) : AnyView(narrowRow(p)) }
                        .background(selectedID == p.id ? Theme.selection : Color.clear)
                        .modifier(RowTaps(position: p, onSelect: onSelect, onOpen: onOpen))
                        .contextMenu { menu(p) }
                    if i < positions.count - 1 {
                        Rectangle().fill(Theme.border.opacity(0.7)).frame(height: 1).padding(.leading, 14)
                    }
                }
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            footer
        }
        .frame(maxWidth: .infinity)
        .onAppear { if LaunchOptions.current.expandRows, expanded.isEmpty { expanded = Set(positions.prefix(2).map(\.id)) } }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: columns

    private var qtyW: CGFloat { 88 * textScale }
    private var priceW: CGFloat { 88 * textScale }
    private var valueW: CGFloat { 104 * textScale }
    private var shareW: CGFloat { 64 * textScale }
    private var gainW: CGFloat { 124 * textScale }
    private var editW: CGFloat { 22 * textScale }

    private var columnHeader: some View {
        HStack(spacing: 10) {
            sortButton("Position", .name, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            label("Menge / Einheit").frame(width: qtyW, alignment: .trailing)
            label("Kurs").frame(width: priceW, alignment: .trailing)
            sortButton("Marktwert", .value, alignment: .trailing).frame(width: valueW, alignment: .trailing)
            label("Anteil").frame(width: shareW, alignment: .trailing)
            sortButton("GuV € / %", .gain, alignment: .trailing).frame(width: gainW, alignment: .trailing)
            Color.clear.frame(width: editW, height: 1)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func label(_ title: LocalizedStringKey) -> some View {
        Text(title).appFont(.caption, weight: .semibold).foregroundStyle(Theme.secondary).lineLimit(1)
    }

    private func sortButton(_ title: LocalizedStringKey, _ key: DepotSortKey, alignment: HorizontalAlignment) -> some View {
        let active = sort.key == key
        return Button { sort.toggle(key) } label: {
            HStack(spacing: 3) {
                Text(title).lineLimit(1)
                Image(systemName: sort.ascending ? "chevron.up" : "chevron.down")
                    .imageScale(.small).opacity(active ? 1 : 0)
            }
            .appFont(.caption, weight: .semibold)
            .foregroundStyle(active ? Theme.text : Theme.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Nach dieser Spalte sortieren")
        .accessibilityValue(active ? (sort.ascending ? Text("aufsteigend sortiert") : Text("absteigend sortiert")) : Text(""))
    }

    private var narrowHeader: some View {
        HStack {
            Text("Sortierung").appFont(.caption).foregroundStyle(Theme.secondary)
            Menu {
                Picker("Sortieren nach", selection: Binding(get: { sort.key }, set: { sort = DepotSort(key: $0, ascending: $0 == .name) })) {
                    Text("Marktwert").tag(DepotSortKey.value)
                    Text("GuV").tag(DepotSortKey.gain)
                    Text("Name").tag(DepotSortKey.name)
                }
                Divider()
                Toggle("Aufsteigend", isOn: $sort.ascending)
            } label: {
                Label(sortTitle, systemImage: sort.ascending ? "arrow.up" : "arrow.down").appFont(.caption, weight: .medium)
            }
            .menuStyle(.borderlessButton).fixedSize()
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var sortTitle: String {
        switch sort.key {
        case .value: String(localized: "Marktwert")
        case .gain: String(localized: "GuV")
        case .name: String(localized: "Name")
        }
    }

    // MARK: rows

    private func nameBlock(_ p: DepotPosition) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(p.displayName).sensitive(p.isOwnItem ? .personal : .labels)
                .appFont(.body, weight: .semibold).foregroundStyle(Theme.text).lineLimit(1)
            HStack(spacing: 3) {
                if !p.identifier.isEmpty { Text(p.identifier).sensitive() }
                if !p.identifier.isEmpty { Text("·") }
                Text(p.asset.classification.compactTitle).sensitive(.labels)
                    .help(p.asset.classification.sourceDescription)
                if let depot = depotLabelOf?(p) { Text("·"); Text(depot).sensitive() }
            }
            .appFont(.callout).foregroundStyle(Theme.secondary).lineLimit(1)
        }
    }

    private func quantityText(_ p: DepotPosition) -> String { NumberText.format(p.holding.quantity) }

    private func unitText(_ p: DepotPosition) -> String {
        p.basis == .percentOfNominal ? String(localized: "Nominal") : String(localized: "Stück")
    }

    /// Bonds quote a percentage of the nominal amount, not an amount per piece.
    private func priceText(_ p: DepotPosition) -> String {
        if p.hidesPrice { return "–" }
        return p.basis == .percentOfNominal
            ? DepotFormat.percent(Double(p.holding.currentPriceCents) / 100)
            : Money.format(p.holding.currentPriceCents, currency: currency)
    }

    private func shareText(_ p: DepotPosition) -> String { p.share.map { DepotFormat.percent($0 * 100, digits: 1) } ?? "–" }

    @ViewBuilder
    private func gainBlock(_ p: DepotPosition, alignment: HorizontalAlignment) -> some View {
        if let g = p.gain {
            VStack(alignment: alignment, spacing: 1) {
                Text(Money.signed(g.cents, currency: currency)).sensitive(.amounts)
                if let pct = g.percent { Text(DepotFormat.percent(pct, signed: true)).sensitive(.amounts) }
            }
            .appFont(.callout, monospacedDigit: true)
            .foregroundStyle(DepotFormat.tint(g.cents))
            .help(g.reported ? String(localized: "Unrealisierte GuV laut Bank") : String(localized: "Aus dem Einstandskurs berechnet"))
        } else {
            Text("–").appFont(.callout).foregroundStyle(Theme.tertiary)
                .help("Kein Einstandskurs geliefert")
        }
    }

    private func wideRow(_ p: DepotPosition) -> some View {
        HStack(spacing: 10) {
            nameBlock(p).frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 1) {
                Text(quantityText(p)).sensitive(.amounts)
                Text(unitText(p)).appFont(.caption2).foregroundStyle(Theme.tertiary)
            }
            .frame(width: qtyW, alignment: .trailing)
            Text(priceText(p)).sensitive(.amounts).frame(width: priceW, alignment: .trailing)
            Text(Money.format(p.holding.valueCents, currency: currency)).sensitive(.amounts)
                .appFont(.body, weight: .medium).foregroundStyle(Theme.text)
                .frame(width: valueW, alignment: .trailing)
            Text(shareText(p)).sensitive(.amounts).foregroundStyle(Theme.secondary).frame(width: shareW, alignment: .trailing)
            gainBlock(p, alignment: .trailing).frame(width: gainW, alignment: .trailing)
            editButton(p).frame(width: editW)
        }
        .appFont(.callout, monospacedDigit: true)
        .lineLimit(1)
        .frame(minHeight: 44)
        .padding(.horizontal, 14).padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func unitShort(_ p: DepotPosition) -> String {
        p.basis == .percentOfNominal ? String(localized: "Nominal") : String(localized: "Stk.")
    }

    /// "160 Stk. · 104,25 € · Aktien · ETF": quantity, price (where there is one) and classification.
    private func narrowSubline(_ p: DepotPosition) -> String {
        [ "\(quantityText(p)) \(unitShort(p))", p.hidesPrice ? nil : priceText(p),
          p.asset.classification.compactTitle.isEmpty ? nil : p.asset.classification.compactTitle ]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// A list row for iPhone and narrow windows: name with its subline on the left, the market value
    /// with gain and share on the right, and a chevron that unfolds the full details. No squeezed
    /// table: what does not fit a line is one tap away.
    private func narrowRow(_ p: DepotPosition) -> some View {
        let gain = p.gain.map { g in
            [Money.signed(g.cents, currency: currency), g.percent.map { DepotFormat.percent($0, signed: true) }]
                .compactMap { $0 }.joined(separator: " · ")
        }
        let share = shareText(p)
        let open = expanded.contains(p.id)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.displayName).sensitive(p.isOwnItem ? .personal : .labels)
                        .appFont(.body, weight: .semibold).foregroundStyle(Theme.text).lineLimit(open ? 3 : 1)
                    // quantity and price are figures: protected like amounts, not just like names
                    Text(narrowSubline(p)).sensitive(.amounts)
                        .appFont(.callout, monospacedDigit: true).foregroundStyle(Theme.secondary).lineLimit(open ? 3 : 1)
                    if let depot = depotLabelOf?(p) {
                        Text(depot).sensitive()
                            .appFont(.caption).foregroundStyle(Theme.tertiary).lineLimit(open ? 3 : 1)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Money.format(p.holding.valueCents, currency: currency)).sensitive(.amounts)
                        .appFont(.body, weight: .medium, monospacedDigit: true).foregroundStyle(Theme.text)
                    ViewThatFits(in: .horizontal) {
                        Text([gain, share].compactMap { $0 }.joined(separator: " · ")).sensitive(.amounts)
                            .foregroundStyle(p.gain.map { DepotFormat.tint($0.cents) } ?? Theme.secondary)
                        VStack(alignment: .trailing, spacing: 1) {
                            if let gain { Text(gain).foregroundStyle(DepotFormat.tint(p.gain?.cents ?? 0)) }
                            Text(share).foregroundStyle(Theme.secondary)
                        }
                        .sensitive()
                    }
                    .appFont(.caption, monospacedDigit: true)
                }
                .lineLimit(1)
                #if os(macOS)
                // a narrow window keeps the pencil at hand; on iPhone it is in the details
                editButton(p)
                #endif
                disclosureButton(open: open) { toggle(p.id) }
            }
            .frame(minHeight: rowHeight)
            if open { details(p) }
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    private var rowHeight: CGFloat {
        #if os(iOS)
        52   // comfortable for a finger
        #else
        44
        #endif
    }

    private func toggle(_ id: String) {
        withAnimation(Motion.animation(.easeInOut(duration: 0.2))) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    private func disclosureButton(open: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "chevron.right").appFont(.caption, weight: .semibold)
                .rotationEffect(.degrees(open ? 90 : 0))
                .foregroundStyle(Theme.secondary)
                #if os(iOS)
                .frame(width: 44, height: 44)
                #else
                .padding(4)
                #endif
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(open ? Text("Details ausblenden") : Text("Details anzeigen"))
    }

    /// Everything the wide table shows in columns, as labelled lines.
    private func details(_ p: DepotPosition) -> some View {
        func line(_ title: LocalizedStringKey, _ value: String, tint: Color = Theme.text) -> some View {
            HStack(alignment: .firstTextBaseline) {
                Text(title).foregroundStyle(Theme.secondary)
                Spacer(minLength: 12)
                Text(value).sensitive(.amounts).foregroundStyle(tint).multilineTextAlignment(.trailing)
            }
        }
        return VStack(alignment: .leading, spacing: 6) {
            line("Menge / Einheit", "\(quantityText(p)) \(unitText(p))")
            if !p.hidesPrice { line("Kurs", priceText(p)) }
            line("Marktwert", Money.format(p.holding.valueCents, currency: currency))
            line("Anteil", shareText(p))
            if let g = p.gain {
                line("GuV", [Money.signed(g.cents, currency: currency), g.percent.map { DepotFormat.percent($0, signed: true) }]
                        .compactMap { $0 }.joined(separator: " · "), tint: DepotFormat.tint(g.cents))
            }
            if !p.identifier.isEmpty { line("ISIN / WKN", p.identifier) }
            #if os(iOS)
            if p.asset.classification.securityKey != nil {
                Button {
                    onClassify(ClassificationEditRequest(name: p.holding.name, classification: p.asset.classification))
                } label: {
                    Label("Klassifizierung bearbeiten", systemImage: "pencil")
                }
                .buttonStyle(.borderless)
                .padding(.top, 2)
            }
            #endif
        }
        .appFont(.callout, monospacedDigit: true)
        .padding(.top, 6).padding(.bottom, 8)
        .padding(.leading, 2)
    }

    /// Edits asset class and instrument; only where the position has a stable classification key.
    @ViewBuilder
    private func editButton(_ p: DepotPosition) -> some View {
        if p.asset.classification.securityKey != nil {
            Button {
                onClassify(ClassificationEditRequest(name: p.holding.name, classification: p.asset.classification))
            } label: {
                Image(systemName: "pencil").appFont(.caption).foregroundStyle(Theme.secondary).padding(4).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Klassifizierung bearbeiten")
            .accessibilityLabel("Klassifizierung bearbeiten")
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    @ViewBuilder
    private func menu(_ p: DepotPosition) -> some View {
        if p.asset.classification.securityKey != nil {
            Button("Klassifizierung bearbeiten", systemImage: "pencil") {
                onClassify(ClassificationEditRequest(name: p.holding.name, classification: p.asset.classification))
            }
        }
        rowMenu(p)
        Button("Position kopieren", systemImage: "doc.on.doc") { copyToPasteboard(HoldingFigures.clipboardLine(p.holding)) }
        Button("Alle Positionen kopieren", systemImage: "doc.on.doc.fill", action: copyAll)
    }

    // MARK: footer

    private var footer: some View {
        let value = positions.reduce(Int64(0)) { $0 + $1.holding.valueCents }
        let share = positions.reduce(0.0) { $0 + ($1.share ?? 0) }
        // from the rows' own gains: merged positions and Sachwerte carry theirs
        let gain = DepotMetrics.unrealized(positions.map(\.gain))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(positions.count == totalCount ? String(localized: "\(totalCount) Positionen") : String(localized: "\(positions.count) von \(totalCount) Positionen"))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                if wide {
                    // the same column widths as the rows above, so every total sits under its column
                    Text(Money.format(value, currency: currency)).sensitive(.amounts).foregroundStyle(Theme.text)
                        .frame(width: valueW, alignment: .trailing)
                    Text(DepotFormat.percent(share * 100, digits: 1)).sensitive(.amounts).foregroundStyle(Theme.secondary)
                        .frame(width: shareW, alignment: .trailing)
                    // amount and percentage like the rows above; the percentage is the sum over the sum of costs
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(gain.map { Money.signed($0.amountCents, currency: currency) } ?? "–").sensitive(.amounts)
                        if let pct = gain?.percent { Text(DepotFormat.percent(pct, signed: true)).sensitive(.amounts) }
                    }
                    .foregroundStyle(gain.map { DepotFormat.tint($0.amountCents) } ?? Theme.tertiary)
                    .frame(width: gainW, alignment: .trailing)
                    Color.clear.frame(width: editW, height: 1)
                } else {
                    Text(Money.format(value, currency: currency)).sensitive(.amounts).foregroundStyle(Theme.text)
                }
            }
            .appFont(.callout, weight: .semibold, monospacedDigit: true)
            if notesCalculatedGain, anyCalculatedGain {
                Text("GuV teils aus dem Einstandskurs berechnet; Positionen ohne Einstandskurs sind nicht enthalten.")
                    .appFont(.caption2).foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

extension DepotPositionsTable where RowMenu == EmptyView {
    init(positions: [DepotPosition], totalCount: Int, sort: Binding<DepotSort>, wide: Bool, currency: String,
         onClassify: @escaping (ClassificationEditRequest) -> Void, copyAll: @escaping () -> Void) {
        self.init(positions: positions, totalCount: totalCount, sort: sort, wide: wide, currency: currency,
                  onClassify: onClassify, copyAll: copyAll, rowMenu: { _ in EmptyView() })
    }
}

/// Click and double click on a row, only when the host wants them (a double click first: a single
/// click may leave the view).
private struct RowTaps: ViewModifier {
    let position: DepotPosition
    let onSelect: ((DepotPosition) -> Void)?
    let onOpen: ((DepotPosition) -> Void)?

    func body(content: Content) -> some View {
        if onSelect != nil || onOpen != nil {
            content
                .onTapGesture(count: 2) { onOpen?(position) }
                .onTapGesture { onSelect?(position) }
                .accessibilityAddTraits(.isButton)
        } else {
            content
        }
    }
}
