import SwiftUI
import GiroCrabCore

/// Which position of which depot the value history sheet shows (#578).
struct PositionHistoryRequest: Identifiable {
    let accountId: Int64
    /// Key of the history (`ValuePosition.position`).
    let key: String
    let name: String
    let currency: String
    var id: String { "\(accountId)-\(key)" }

    init(accountId: Int64, position: ValuePosition) {
        self.accountId = accountId
        key = position.position
        name = position.name
        currency = position.currency
    }
}

/// The daily value of one position, from the fetches and an import. It is the value of the
/// position (quantity × price), so a purchase or a sale moves it: it is no price chart.
struct PositionHistorySheet: View {
    private enum Load {
        case loading
        case failed(String)
        case loaded([DepotValuePoint])
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: PositionHistoryRequest
    @State private var load = Load.loading

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.name).sensitive(.labels).appFont(.headline).lineLimit(2)
            content
            Text("Wert der Position (Menge × Kurs). Käufe und Verkäufe verändern ihn – er ist kein Kursverlauf.")
                .appFont(.caption).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        #if os(macOS)
        .frame(width: 560)
        #endif
        .task(id: request.id) { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        switch load {
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 200)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("Wertverlauf konnte nicht geladen werden", systemImage: "exclamationmark.triangle")
                    .appFont(.caption, weight: .semibold).foregroundStyle(Theme.warning)
                Text(message).appFont(.caption2).foregroundStyle(Theme.tertiary).lineLimit(3)
                Button("Erneut versuchen") { Task { await reload() } }.buttonStyle(.borderless).appFont(.caption)
            }
        case .loaded(let points):
            if points.count < 2 {
                Text("Noch kein Verlauf für diese Position").appFont(.callout).foregroundStyle(Theme.secondary)
            } else {
                DepotValueChart(points: points, currency: request.currency).frame(height: 200).sensitive(.amounts)
                summary(points)
            }
        }
    }

    private func summary(_ points: [DepotValuePoint]) -> some View {
        let first = points[0], last = points[points.count - 1]
        return VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Verlauf ab", value: DateText.medium(first.date))
            if last.valueCents == 0 {
                LabeledContent("Nicht mehr im Depot seit", value: DateText.medium(last.date))
            } else {
                LabeledContent("Letzter Wert") {
                    Text(Money.format(last.valueCents, currency: request.currency)).sensitive(.amounts)
                }
            }
        }
        .appFont(.callout, monospacedDigit: true)
    }

    private func reload() async {
        let id = request.accountId, key = request.key
        load = .loading
        do {
            let points = try await model.vaultOffMain { try $0.positionValueHistory(accountId: id, position: key) }
            // nil: locked or swapped meanwhile
            guard !Task.isCancelled, let points else { return }
            load = .loaded(points)
        } catch {
            guard !Task.isCancelled else { return }
            load = .failed(describe(error))
        }
    }
}

/// Positions of a depot that are no longer held but have a value history (#578), collapsed below
/// the positions table; each opens its history.
struct SoldPositionsSection: View {
    let positions: [ValuePosition]
    let open: (ValuePosition) -> Void
    @AppStorage("depotSoldPositionsExpanded") private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(spacing: 0) {
                ForEach(positions, id: \.position) { p in
                    Button { open(p) } label: { row(p) }
                        .buttonStyle(.plain)
                        .help("Wertverlauf anzeigen")
                    if p.position != positions.last?.position { Divider() }
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Verkaufte Positionen (\(positions.count))").appFont(.callout, weight: .semibold)
        }
        .padding(.horizontal, 4)
    }

    private func row(_ p: ValuePosition) -> some View {
        HStack(spacing: 10) {
            Text(p.name.isEmpty ? p.position : p.name).sensitive(.labels).lineLimit(1)
            Spacer(minLength: 8)
            Text(soldText(p)).foregroundStyle(Theme.secondary).lineLimit(1).fixedSize()
            Image(systemName: "chart.xyaxis.line").foregroundStyle(Theme.secondary)
        }
        .appFont(.callout, monospacedDigit: true)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Wertverlauf anzeigen"))
    }

    /// "verkauft 12.03.2025" after a closing 0, else "zuletzt 12.03.2025" (no longer reported).
    private func soldText(_ p: ValuePosition) -> String {
        p.lastValueCents == 0
            ? String(localized: "verkauft \(DateText.medium(p.lastDate))")
            : String(localized: "zuletzt \(DateText.medium(p.lastDate))")
    }
}
