import SwiftUI
import GiroCrabCore

/// Securities activities of one depot (`security_transactions`): never cash bookings of the
/// clearing account, never used to rebuild positions. A booking on the clearing account is
/// reachable through the transaction's own `cash_transaction_id` link.
struct DepotActivitiesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.textScale) private var textScale
    @Environment(\.reportRedaction) private var redaction
    /// All activities of the depot; `shown` is the filtered subset.
    let all: [SecurityTransaction]
    let shown: [SecurityTransaction]
    @Binding var filter: DepotActivityFilter
    let query: String
    let periodTitle: String
    let wide: Bool

    private var firstRecorded: String? { all.map(\.bookingDate).filter { !$0.isEmpty }.min() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if all.isEmpty {
                ContentUnavailableView(
                    "Keine Aktivitäten verfügbar",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Für dieses Depot sind keine Wertpapieraktivitäten gespeichert. Nicht jede Bank liefert sie – das heißt nicht, dass es keine Geschäfte, Ausschüttungen oder Kosten gab.")
                )
                .padding(.top, 20)
            } else {
                controls
                if shown.isEmpty {
                    empty
                } else {
                    list
                }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if wide {
                    Picker("Art", selection: $filter) {
                        ForEach(DepotActivityFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).fixedSize()
                } else {
                    Picker("Art", selection: $filter) {
                        ForEach(DepotActivityFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu).fixedSize()
                }
            }
            .labelsHidden()
            .help("Kosten: eigene Gebühren- und Steuerzeilen sowie Aktivitäten mit Gebühren oder Steuern")
            Text(info).appFont(.caption).foregroundStyle(Theme.secondary)
        }
    }

    private var info: String {
        var parts = [String(localized: "\(shown.count) von \(all.count) Aktivitäten"), String(localized: "Zeitraum: \(periodTitle)")]
        if let first = firstRecorded { parts.append(String(localized: "erfasst ab \(DateText.medium(first))")) }
        return parts.joined(separator: " · ")
    }

    /// Search without hits, period without activities and an empty filter are different things;
    /// none of them proves that nothing happened.
    @ViewBuilder
    private var empty: some View {
        if !query.isEmpty {
            ContentUnavailableView(
                "Keine Treffer",
                systemImage: "magnifyingglass",
                description: Text("Keine Aktivität passt zu „\(redaction.masking(query))“.")
            )
            .padding(.top, 20)
        } else {
            ContentUnavailableView(
                "Keine Aktivitäten gefunden",
                systemImage: "tray",
                description: Text("Im gewählten Zeitraum und Filter sind keine gespeicherten Aktivitäten. Das ist kein Nachweis, dass keine stattgefunden haben.")
            )
            .padding(.top, 20)
        }
    }

    // MARK: rows

    private var dateW: CGFloat { 92 * textScale }
    private var kindW: CGFloat { 124 * textScale }
    private var qtyW: CGFloat { 80 * textScale }
    private var valueW: CGFloat { 112 * textScale }
    private var costW: CGFloat { 76 * textScale }
    private var linkW: CGFloat { 28 * textScale }

    private var list: some View {
        VStack(spacing: 0) {
            if wide {
                HStack(spacing: 10) {
                    head("Datum").frame(width: dateW, alignment: .leading)
                    head("Wertpapier").frame(maxWidth: .infinity, alignment: .leading)
                    head("Art").frame(width: kindW, alignment: .leading)
                    head("Menge").frame(width: qtyW, alignment: .trailing)
                    head("Bruttobetrag").frame(width: valueW, alignment: .trailing)
                        .help("Bruttobetrag der Aktivität ohne Gebühren und Steuern, bei Ausschüttungen vor Quellensteuer. Gebühren und Steuern stehen in eigenen Spalten; der tatsächliche Geldbetrag steht in der verknüpften Buchung des Verrechnungskontos.")
                    head("Gebühren").frame(width: costW, alignment: .trailing)
                    head("Steuern").frame(width: costW, alignment: .trailing)
                    Color.clear.frame(width: linkW)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            LazyVStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
                    if wide { wideRow(t) } else { narrowRow(t) }
                    if i < shown.count - 1 {
                        Rectangle().fill(Theme.border.opacity(0.7)).frame(height: 1).padding(.leading, 14)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { if LaunchOptions.current.expandRows, expanded.isEmpty { expanded = Set(shown.prefix(2).map(\.id)) } }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func head(_ title: LocalizedStringKey) -> some View {
        Text(title).appFont(.caption, weight: .semibold).foregroundStyle(Theme.secondary).lineLimit(1)
    }

    private func kindText(_ t: SecurityTransaction) -> String { DepotActivities.kindTitle(t) }

    private func nameText(_ t: SecurityTransaction) -> String {
        t.name.isEmpty ? (t.isin.isEmpty ? t.wkn : t.isin) : t.name
    }

    private func idText(_ t: SecurityTransaction) -> String { t.isin.isEmpty ? t.wkn : t.isin }

    private func quantityText(_ t: SecurityTransaction) -> String { t.quantity != 0 ? NumberText.format(t.quantity) : "–" }

    private func currency(_ t: SecurityTransaction) -> String { t.currency.isEmpty ? "EUR" : t.currency }

    /// Own fee and tax lines are costs, not a securities value: their amount stands in the fee or
    /// tax column and the securities value stays empty.
    private func isCostLine(_ t: SecurityTransaction) -> Bool { t.direction == .fee || t.direction == .tax }

    private func valueText(_ t: SecurityTransaction) -> String {
        isCostLine(t) ? "–" : Money.format(t.valueCents, currency: currency(t))
    }

    private func feeText(_ t: SecurityTransaction) -> String {
        let cents = DepotActivities.feeCents(t)
        return cents == 0 ? "–" : Money.format(cents, currency: currency(t))
    }

    private func taxText(_ t: SecurityTransaction) -> String {
        let cents = DepotActivities.taxCents(t)
        return cents == 0 ? "–" : Money.format(cents, currency: currency(t))
    }

    /// Narrow rows have one amount: the securities value, or the cost of a fee/tax line.
    private func narrowAmountText(_ t: SecurityTransaction) -> String {
        switch t.direction {
        case .fee: feeText(t)
        case .tax: taxText(t)
        default: valueText(t)
        }
    }

    private func dateBlock(_ t: SecurityTransaction) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(DateText.medium(t.bookingDate)).foregroundStyle(Theme.text)
            if !t.settlementDate.isEmpty, t.settlementDate != t.bookingDate {
                Text("Valuta \(DateText.medium(t.settlementDate))").appFont(.caption2).foregroundStyle(Theme.tertiary)
            }
        }
    }

    @ViewBuilder
    private func jump(_ t: SecurityTransaction) -> some View {
        if let id = t.cashTransactionId {
            Button { model.revealBooking(id) } label: {
                Image(systemName: "arrow.right.circle").appFont(.body)
            }
            .buttonStyle(.borderless)
            .help("Zur zugehörigen Buchung des Verrechnungskontos")
            .accessibilityLabel("Zur Buchung des Verrechnungskontos springen")
        }
    }

    private func wideRow(_ t: SecurityTransaction) -> some View {
        HStack(spacing: 10) {
            dateBlock(t).frame(width: dateW, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(nameText(t)).sensitive(.labels).appFont(.body, weight: .semibold).foregroundStyle(Theme.text).lineLimit(1)
                if !idText(t).isEmpty { Text(idText(t)).sensitive().appFont(.callout).foregroundStyle(Theme.secondary).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(kindText(t)).foregroundStyle(Theme.text)
                if !t.bookingText.isEmpty, t.bookingText != kindText(t) {
                    Text(t.bookingText).sensitive().appFont(.caption2).foregroundStyle(Theme.tertiary)
                }
            }
            .frame(width: kindW, alignment: .leading)
            Text(quantityText(t)).sensitive(.amounts).foregroundStyle(Theme.secondary).frame(width: qtyW, alignment: .trailing)
            Text(valueText(t)).sensitive(.amounts).foregroundStyle(Theme.text).frame(width: valueW, alignment: .trailing)
            Text(feeText(t)).sensitive(.amounts).foregroundStyle(Theme.secondary).frame(width: costW, alignment: .trailing)
            Text(taxText(t)).sensitive(.amounts).foregroundStyle(Theme.secondary).frame(width: costW, alignment: .trailing)
            jump(t).frame(width: linkW)
        }
        .appFont(.callout, monospacedDigit: true)
        .lineLimit(1)
        .frame(minHeight: 44)
        .padding(.horizontal, 14).padding(.vertical, 5)
        .accessibilityElement(children: .contain)
    }

    @State private var expanded: Set<Int64> = []

    private var rowHeight: CGFloat {
        #if os(iOS)
        52   // comfortable for a finger
        #else
        44
        #endif
    }

    /// A list row for iPhone and narrow windows: name, date and kind on the left, the amount on the
    /// right; the chevron unfolds everything the wide table shows in columns.
    private func narrowRow(_ t: SecurityTransaction) -> some View {
        let open = expanded.contains(t.id)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(nameText(t)).sensitive(.labels).appFont(.body, weight: .semibold)
                        .foregroundStyle(Theme.text).lineLimit(open ? 3 : 1)
                    Text([DateText.medium(t.bookingDate), kindText(t)].joined(separator: " · "))
                        .sensitive().appFont(.callout).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(narrowAmountText(t)).sensitive(.amounts).appFont(.body, weight: .medium, monospacedDigit: true)
                    .foregroundStyle(Theme.text).lineLimit(1).fixedSize()
                #if os(macOS)
                jump(t)   // a narrow window keeps the jump at hand; on iPhone it is in the details
                #endif
                Button {
                    withAnimation(Motion.animation(.easeInOut(duration: 0.2))) {
                        if open { expanded.remove(t.id) } else { expanded.insert(t.id) }
                    }
                } label: {
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
            .frame(minHeight: rowHeight)
            if open { details(t) }
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
        .accessibilityElement(children: .contain)
    }

    private func details(_ t: SecurityTransaction) -> some View {
        func line(_ title: LocalizedStringKey, _ value: String) -> some View {
            HStack(alignment: .firstTextBaseline) {
                Text(title).foregroundStyle(Theme.secondary)
                Spacer(minLength: 12)
                Text(value).sensitive(.amounts).foregroundStyle(Theme.text).multilineTextAlignment(.trailing)
            }
        }
        return VStack(alignment: .leading, spacing: 6) {
            if !t.settlementDate.isEmpty, t.settlementDate != t.bookingDate {
                line("Valuta", DateText.medium(t.settlementDate))
            }
            if t.quantity != 0 { line("Menge", quantityText(t)) }
            if !isCostLine(t) { line("Bruttobetrag", valueText(t)) }
            if feeText(t) != "–" { line("Gebühren", feeText(t)) }
            if taxText(t) != "–" { line("Steuern", taxText(t)) }
            if !idText(t).isEmpty { line("ISIN / WKN", idText(t)) }
            if !t.bookingText.isEmpty, t.bookingText != kindText(t) { line("Bankhinweis", t.bookingText) }
            #if os(iOS)
            if let id = t.cashTransactionId {
                Button { model.revealBooking(id) } label: {
                    Label("Zur Buchung des Verrechnungskontos", systemImage: "arrow.right.circle")
                }
                .buttonStyle(.borderless)
                .padding(.top, 2)
            }
            #endif
        }
        .appFont(.callout, monospacedDigit: true)
        .padding(.top, 6).padding(.bottom, 8)
    }
}
