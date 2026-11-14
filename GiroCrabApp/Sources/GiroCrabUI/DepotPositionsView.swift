import SwiftUI
import GiroCrabCore

/// Positions of a depot below its header, as cards like the day cards of
/// the booking list: securities from the last sync, or Sachwerte (#87) –
/// held items, and sold ones in their own card.
struct DepotPositionsView: View {
    @Environment(AppModel.self) private var model
    let account: Account
    @State private var holdings: [Holding] = []
    @AppStorage("showSoldAssets") private var showSold = false
    @State private var deleting: AssetItem?

    private var tangible: Bool { model.isTangible(account.id) }

    var body: some View {
        VStack(spacing: 14) {
            if tangible { assets } else { securities }
        }
        // a click on the empty space around the cards ends the item selection;
        // a background layer, so it never sees clicks on the rows (a tap
        // gesture on the stack itself fired late after the rows' double-click
        // recogniser gave up and undid every selection)
        .frame(maxWidth: .infinity, minHeight: tangible ? 420 : nil, alignment: .top)
        .background {
            if tangible {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.deselectAssetItem() }
            }
        }
        .task(id: "\(account.id)-\(account.balanceCents)-\(account.balanceDate)") {
            if !tangible { holdings = model.holdings(for: account.id) }
        }
        .onChange(of: account.id) { model.selectAssetItem(nil) }
        .confirmationDialog("„\(deleting?.setup.name ?? "")“ löschen?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                if let item = deleting {
                    do { try model.changeAssets { try $0.deleteAssetItem(itemId: item.id) } } catch { model.errorMessage = describe(error) }
                }
                deleting = nil
            }
        } message: {
            Text("Der Sachwert und sein Verlauf werden entfernt.")
        }
    }

    // MARK: securities

    @ViewBuilder
    private var securities: some View {
        if holdings.isEmpty {
            ContentUnavailableView(
                "Keine Positionen",
                systemImage: "chart.line.uptrend.xyaxis",
                description: Text("Positionen kommen mit dem nächsten Abruf. Käufe, Verkäufe und Sparpläne stehen als Buchungen im Verrechnungskonto.")
            )
            .padding(.top, 40)
        } else {
            PositionCard(items: holdings) {
                cardHeader("Positionen", total: holdings.reduce(0) { $0 + $1.valueCents })
            } row: { h in
                PositionRow(symbol: "chart.line.uptrend.xyaxis",
                            name: h.name.isEmpty ? (h.isin.isEmpty ? h.wkn : h.isin) : h.name,
                            detail: "\(NumberText.format(h.quantity)) × \(Money.format(h.currentPriceCents)) · \(h.isin.isEmpty ? h.wkn : h.isin)",
                            valueCents: h.valueCents,
                            gain: Self.calculatedGain(h))
                    .contextMenu {
                        Button("Position kopieren", systemImage: "doc.on.doc") { copyToPasteboard(Self.line(h)) }
                        Button("Alle Positionen kopieren", systemImage: "doc.on.doc.fill") {
                            copyToPasteboard(holdings.map(Self.line).joined(separator: "\n"))
                        }
                    }
            }
        }
    }

    /// Derived from existing holdings fields; missing cost prices stay unknown.
    static func calculatedGain(_ holding: Holding) -> (cents: Int64, percent: Double)? {
        guard holding.quantity.isFinite, holding.quantity > 0,
              holding.purchasePriceCents > 0, holding.valueCents >= 0 else { return nil }
        let cost = (holding.quantity * Double(holding.purchasePriceCents)).rounded()
        guard cost.isFinite, cost >= 1, cost < Double(Int64.max) else { return nil }
        let (gain, overflow) = holding.valueCents.subtractingReportingOverflow(Int64(cost))
        guard !overflow else { return nil }
        return (gain, Double(gain) / cost * 100)
    }

    /// One position as plain text: name, ISIN/WKN, quantity, price, value.
    static func line(_ h: Holding) -> String {
        let id = h.isin.isEmpty ? h.wkn : h.isin
        let qty = h.quantity.formatted(.number.precision(.fractionLength(0...4)))
        return [h.name, id, "\(qty) × \(Money.format(h.currentPriceCents))", Money.format(h.valueCents)]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: Sachwerte

    @ViewBuilder
    private var assets: some View {
        let items = model.assetItems(account.id)
        let held = items.filter { !$0.sold }.sorted { $0.holding.valueCents > $1.holding.valueCents }
        let sold = items.filter(\.sold).sorted { $0.setup.name.localizedStandardCompare($1.setup.name) == .orderedAscending }
        if items.isEmpty {
            ContentUnavailableView {
                Label("Noch keine Sachwerte", systemImage: "shippingbox")
            } description: {
                Text("Fügen Sie z. B. Goldmünzen, Barren oder ein Auto hinzu.")
            } actions: {
                Button("Sachwert hinzufügen …") { model.openAssetEditor(accountId: account.id) }
            }
            .padding(.top, 40)
        }
        if !held.isEmpty {
            PositionCard(items: held, onHeaderTap: { model.deselectAssetItem() }) {
                // No total here: the header above already shows it.
                cardHeader("Positionen")
            } row: { assetRow($0) }
        }
        if !sold.isEmpty {
            PositionCard(items: showSold ? sold : []) {
                Button {
                    withAnimation(Motion.animation(.easeInOut(duration: 0.2))) { showSold.toggle() }
                } label: {
                    HStack {
                        Image(systemName: "chevron.right")
                            .appFont(.caption, weight: .semibold)
                            .rotationEffect(.degrees(showSold ? 90 : 0))
                        Text("Ehemalige Positionen (\(sold.count))").appFont(.subheadline, weight: .semibold)
                        Spacer()
                    }
                    .foregroundStyle(Theme.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(showSold ? Text("Ausgeklappt") : Text("Eingeklappt"))
            } row: { assetRow($0) }
        }
    }

    private func assetRow(_ item: AssetItem) -> some View {
        let selected = model.assetStore.selected == item.id
        return PositionRow(symbol: AssetSymbols.symbol(of: item),
                           name: item.setup.name,
                           detail: detail(item),
                           valueCents: item.holding.valueCents,
                           warning: item.missingPriceDate != nil,
                           selected: selected,
                           dimmed: item.sold,
                           nameRedaction: .personal)
            .onTapGesture { model.selectAssetItem(item.id) }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                // the second click toggled the selection off again: keep the item selected
                if model.assetStore.selected != item.id { model.selectAssetItem(item.id) }
                model.openAssetEditor(accountId: account.id, itemId: item.id)
            })
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .contextMenu {
                Button("Sachwert bearbeiten …") { model.openAssetEditor(accountId: account.id, itemId: item.id) }
                // gold follows the price API; only manual items carry own values
                if item.setup.priceSource == "manual" {
                    Button("Bewertungen bearbeiten …") { model.openAssetAction(.values, itemId: item.id) }
                }
                Button("Anzahl bearbeiten …") { model.openAssetAction(.quantities, itemId: item.id) }
                if !item.sold {
                    Button("Sachwert verkaufen …") { model.openAssetAction(.sell, itemId: item.id) }
                }
                Divider()
                Button("Sachwert löschen …", role: .destructive) { deleting = item }
            }
    }

    private func detail(_ item: AssetItem) -> String {
        if item.sold, let sale = item.quantities.last {
            return String(localized: "verkauft am \(DateText.medium(sale.date))")
        }
        if let missing = item.missingPriceDate {
            return String(localized: "Kurs für den \(DateText.medium(missing)) fehlt")
        }
        let qty = "\(NumberText.format(item.holding.quantity)) × \(Money.format(item.holding.currentPriceCents))"
        guard !item.valueDate.isEmpty else { return qty + " · " + String(localized: "noch kein Kurs") }
        let source = item.setup.priceSource == "manual" ? String(localized: "Wert vom \(DateText.medium(item.valueDate))") : String(localized: "Kurs vom \(DateText.medium(item.valueDate))")
        return "\(qty) · \(source)"
    }

    private func cardHeader(_ title: LocalizedStringKey, total: Int64? = nil) -> some View {
        HStack {
            Text(title).appFont(.subheadline, weight: .semibold).foregroundStyle(Theme.text)
            Spacer()
            if let total {
                Text(Money.format(total)).sensitive().appFont(.subheadline, monospacedDigit: true).foregroundStyle(Theme.secondary)
            }
        }
    }
}

/// A card with a header and rows, styled like the booking list's day cards.
struct PositionCard<Item, Header: View, Row: View>: View {
    let items: [Item]
    /// Click on the header's empty space (Sachwerte: end the item selection).
    var onHeaderTap: (() -> Void)?
    @ViewBuilder let header: () -> Header
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(spacing: 0) {
            header()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background {
                    if let onHeaderTap {
                        Color.clear.contentShape(Rectangle()).onTapGesture(perform: onHeaderTap)
                    }
                }
            if !items.isEmpty {
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                row(item)
                if i < items.count - 1 {
                    Rectangle().fill(Theme.border.opacity(0.7)).frame(height: 1).padding(.leading, 64)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// One position, laid out like a booking row; shared by securities and Sachwerte.
struct PositionRow: View {
    let symbol: String
    let name: String
    let detail: String
    let valueCents: Int64
    var warning = false
    var selected = false
    var dimmed = false
    /// Bug report screenshot (#301): security names hide on request, own items (house, car) always.
    var nameRedaction: ReportRedaction = .labels
    /// Securities: gain or loss against the cost price, if the bank sent one.
    var gain: (cents: Int64, percent: Double)?

    var body: some View {
        HStack(spacing: 12) {
            AssetSymbolTile(symbol: symbol)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .sensitive(nameRedaction)
                    .appFont(.body, weight: .semibold)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                HStack(spacing: 3) {
                    if warning { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning) }
                    Text(detail)
                }
                .sensitive()
                .appFont(.callout)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if !(dimmed && valueCents == 0) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Money.format(valueCents))
                        .sensitive()
                        .appFont(.body, weight: .medium, monospacedDigit: true)
                        .foregroundStyle(Theme.text)
                    if let gain {
                        Text("GuV (berechnet): \(Money.format(gain.cents)) (\(gain.percent.formatted(.number.precision(.fractionLength(2)))) %)")
                            .sensitive()
                            .appFont(.caption, monospacedDigit: true)
                            .foregroundStyle(gain.cents < 0 ? Color.red : Color.green)
                    }
                }
                .lineLimit(1)
                .fixedSize()
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .opacity(dimmed ? 0.6 : 1)
        .background(selected ? Theme.selection : Color.clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
