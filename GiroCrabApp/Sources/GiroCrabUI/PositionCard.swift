import SwiftUI
import GiroCrabCore

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
    var classification: AssetClassification?

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
                    if let classification {
                        Text(classification.compactTitle)
                            .help(classification.sourceDescription)
                            .layoutPriority(1)
                        Text("·")
                    }
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
