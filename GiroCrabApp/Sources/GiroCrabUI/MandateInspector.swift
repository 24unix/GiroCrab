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
                    Text("\(m.scheme.title) · \(m.typeText) · \(m.active ? m.sequenceText : String(localized: "Inaktiv"))")
                        .appFont(.callout).foregroundStyle(Theme.secondary)
                        .help(m.typeHelp)
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
                returnsCard(m)
                bookingsCard
                HStack {
                    Button("Bearbeiten …", systemImage: "pencil") { model.editMandate(m) }
                    Button(m.active ? "Deaktivieren" : "Aktivieren", systemImage: m.active ? "pause.circle" : "play.circle") {
                        model.setMandateActive(m, !m.active)
                    }
                }
                .buttonStyle(.bordered)
            }
            .task(id: "\(m.id)-\(model.mandatesVersion)") { await model.loadMandateBookings(m) }
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
    private func returnsCard(_ m: Mandate) -> some View {
        let open = model.openReturns(of: m)
        if let last = open.first {
            VStack(alignment: .leading, spacing: 8) {
                Label("Rücklastschrift – bitte prüfen", systemImage: "exclamationmark.triangle.fill")
                    .appFont(.headline).foregroundStyle(Theme.negative)
                Text("\(DateText.medium(last.date)) · \(Money.format(abs(last.amountCents)))" + (last.reason.isEmpty ? "" : " · \(last.reason)"))
                    .appFont(.callout).sensitive()
                Text("Die Bank hat einen Einzug zurückgegeben. Prüfe die Angaben des Mandats, bevor du erneut einziehst.")
                    .appFont(.callout).foregroundStyle(Theme.secondary)
                // side by side when they fit, else stacked: the inspector is narrow
                // and larger text sizes must not cut the labels
                ViewThatFits(in: .horizontal) {
                    HStack { returnButtons(m) }
                    VStack(alignment: .leading) { returnButtons(m) }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    @ViewBuilder
    private var bookingsCard: some View {
        if !model.mandateBookings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Buchungen zu diesem Mandat").appFont(.caption).foregroundStyle(Theme.secondary)
                ForEach(model.mandateBookings.prefix(6), id: \.bookingId) { b in
                    HStack {
                        Text(DateText.medium(b.date)).appFont(.callout)
                        if b.isReturn {
                            Text(b.reason.isEmpty ? String(localized: "Rücklastschrift") : b.reason)
                                .appFont(.caption).foregroundStyle(Theme.negative)
                        }
                        Spacer()
                        Text(Money.format(b.amountCents)).appFont(.callout, monospacedDigit: true).sensitive()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    @ViewBuilder
    private func returnButtons(_ m: Mandate) -> some View {
        Button("Als geprüft markieren", systemImage: "checkmark.circle") { model.acknowledgeReturns(m) }
            .fixedSize()
        if m.active {
            Button("Deaktivieren", systemImage: "pause.circle") { model.setMandateActive(m, false) }
                .fixedSize()
        }
    }

    private func field(_ label: LocalizedStringKey, _ value: String, mono: Bool = false, sensitive: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).appFont(.caption).foregroundStyle(Theme.secondary)
            let t = Text(value).appFont(.callout, monospacedDigit: mono).textSelection(.enabled)
            if sensitive { t.sensitive() } else { t }
        }
    }
}
