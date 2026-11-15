import SwiftUI
import UniformTypeIdentifiers
import GiroCrabCore

/// Inspector of „Lastschriften“: the selected mandate.
struct MandateInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let m = model.mandates.first(where: { $0.id == model.selectedMandateID }) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(m.debtorName).appFont(.title3, weight: .semibold).sensitive()
                    Text("\(m.scheme.title) · \(m.active ? m.sequenceText : String(localized: "Inaktiv"))")
                        .appFont(.callout).foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
                VStack(alignment: .leading, spacing: 10) {
                    field("Mandatsreferenz", m.reference)
                    field("Unterschrieben am", DateText.medium(m.signedDate), sensitive: false)
                    field("IBAN", m.debtorIban, mono: true)
                    if !m.debtorBic.isEmpty { field("BIC", m.debtorBic, mono: true) }
                    if m.defaultAmountCents > 0 { field("Betrag", Money.format(m.defaultAmountCents), mono: true) }
                    if !m.defaultPurpose.isEmpty { field("Verwendungszweck", m.defaultPurpose) }
                    if let last = m.lastCollected { field("Zuletzt eingezogen", DateText.medium(last), sensitive: false) }
                    if !m.note.isEmpty { field("Notiz", m.note) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
                HStack {
                    Button("Bearbeiten …", systemImage: "pencil") { model.editMandate(m) }
                    Button(m.active ? "Deaktivieren" : "Aktivieren", systemImage: m.active ? "pause.circle" : "play.circle") {
                        model.setMandateActive(m, !m.active)
                    }
                }
                .buttonStyle(.bordered)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Label("Kein Mandat ausgewählt", systemImage: "doc.text")
                    .appFont(.headline)
                Text("Wähle ein Mandat, um Details zu sehen.")
                    .appFont(.callout).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    @ViewBuilder
    private func field(_ label: LocalizedStringKey, _ value: String, mono: Bool = false, sensitive: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).appFont(.caption).foregroundStyle(Theme.secondary)
            let t = Text(value).appFont(.callout, monospacedDigit: mono).textSelection(.enabled)
            if sensitive { t.sensitive() } else { t }
        }
    }
}
