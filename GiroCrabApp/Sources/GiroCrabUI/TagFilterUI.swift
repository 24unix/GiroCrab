import SwiftUI
import GiroCrabCore

// Tag filter of the booking list (#228, part 3): a header button that opens a
// popover to tick tags, with bookings and sum per tag under the list's other
// filters (period, accounts, category, status, search).

/// Header button of the tag filter; the popover hangs on the filter row
/// (`BalanceHeaderView.filterRow`), outside its `ViewThatFits`.
struct TagFilterButton: View {
    @Environment(AppModel.self) private var model
    /// The button's frame in the filter row (`rowSpace`), where the popover anchors.
    var frameChanged: (CGRect) -> Void = { _ in }
    static let rowSpace = "filterRow"

    var body: some View {
        Button { model.showTagFilter.toggle() } label: {
            // as large as the period and status menus beside it
            Label(model.tagFilterTitle, systemImage: model.tagFilter.isActive ? "tag.fill" : "tag")
                .appFont(.body)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(model.tagFilter.isActive ? Theme.accent : Theme.text)
        .fixedSize()
        .help("Nach Tags filtern")
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.rowSpace)) } action: { frameChanged($0) }
    }
}

/// Tick tags (several = bookings carrying all of them) or „Ohne Tag“. Each row shows what
/// ticking it alone would list: its bookings and their sum under the other filters.
struct TagFilterPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.textScale) private var textScale
    /// nil while loading (or when the vault is locked).
    @State private var totals: [Int64?: TagTotal]?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Nach Tags filtern").appFont(.headline)
                Text("Mehrere Tags: nur Buchungen, die alle tragen. Anzahl und Summe gelten für den Zeitraum und die übrigen Filter der Liste.")
                    .appFont(.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.tags, id: \.id) { tag in
                        row(checked: model.tagFilter.tagIDs.contains(tag.id), total: totals?[tag.id]) {
                            Circle()
                                .fill(tag.colorHex.isEmpty ? Theme.secondary : Color(hex: tag.colorHex))
                                .frame(width: 8, height: 8)
                                .frame(width: 16 * textScale)
                            Text(tag.name).appFont(.body).lineLimit(1).truncationMode(.tail).sensitive()
                        } toggle: {
                            model.toggleTagFilter(tag.id)
                        }
                    }
                }
            }
            .frame(maxHeight: 300 * textScale)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            row(checked: model.tagFilter.untagged, total: totals?[nil]) {
                Image(systemName: "tag.slash").imageScale(.small).foregroundStyle(Theme.secondary)
                    .frame(width: 16 * textScale)
                Text("Ohne Tag").appFont(.body)
            } toggle: {
                model.toggleUntaggedFilter()
            }
            Divider()
            HStack {
                if model.tagFilter.isActive {
                    Text("Angezeigt: \(model.bookingCountLabel) Buchungen")
                        .appFont(.caption)
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button("Zurücksetzen") { model.clearTagFilter() }
                    .disabled(!model.tagFilter.isActive)
            }
        }
        .padding(12)
        .frame(width: 340 * textScale)
        .task { totals = await model.loadTagTotals() }
    }

    /// One tickable line: box, label, bookings and sum.
    private func row<Label: View>(checked: Bool, total: TagTotal?,
                                  @ViewBuilder label: () -> Label,
                                  toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? Theme.accent : Theme.secondary)
                label()
                Spacer(minLength: 12)
                figures(total)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }

    @ViewBuilder
    private func figures(_ total: TagTotal?) -> some View {
        if totals == nil {
            ProgressView().controlSize(.mini)
        } else {
            let count = total?.bookingCount ?? 0
            HStack(spacing: 10) {
                Text(count, format: .number)
                    .appFont(.callout, monospacedDigit: true)
                    .foregroundStyle(count == 0 ? Theme.tertiary : Theme.secondary)
                Text(total.map { Money.format($0.sumCents) } ?? "–")
                    .appFont(.callout, monospacedDigit: true)
                    .foregroundStyle(count == 0 ? Theme.tertiary : Theme.text)
                    .frame(minWidth: 90 * textScale, alignment: .trailing)
                    .sensitive()
            }
            .fixedSize()
        }
    }
}
