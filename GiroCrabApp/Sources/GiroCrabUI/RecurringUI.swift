import SwiftUI
import GiroCrabCore

// Wiederkehrende Buchungen (GitHub #35): inspector card, month overview sheet.

extension RecurrenceInterval {
    static let fixed: [RecurrenceInterval] = [.monthly, .quarterly, .halfYearly, .yearly]

    var label: String {
        switch self {
        case .monthly: return String(localized: "Monatlich")
        case .quarterly: return String(localized: "Vierteljährlich")
        case .halfYearly: return String(localized: "Halbjährlich")
        case .yearly: return String(localized: "Jährlich")
        case .custom: return String(localized: "Individuell")
        }
    }
}

extension RecurringSeries {
    /// "Monatlich" or "Individuell (15.03., 15.08.)".
    var intervalText: String {
        guard interval == .custom, !customDates.isEmpty else { return interval.label }
        let days = customDates.map { mmdd -> String in
            let p = mmdd.split(separator: "-")
            return p.count == 2 ? "\(p[1]).\(p[0])." : mmdd
        }
        return "\(interval.label) (\(days.joined(separator: ", ")))"
    }
}

/// Inspector card: is this booking part of a recurring series? Mark / change / ignore.
struct RecurringCard: View {
    @Environment(AppModel.self) private var model
    let booking: Booking
    @State private var editingCustom = false

    var body: some View {
        let series = model.recurringSeries(for: booking)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Wiederkehrend", systemImage: "repeat")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(series == nil ? Theme.text : Theme.accent)
                Spacer()
                Menu {
                    ForEach(RecurrenceInterval.fixed, id: \.self) { i in
                        Button(i.label) { model.markRecurring(booking, i) }
                    }
                    Button("Individuell …") { editingCustom = true }
                    if let s = series {
                        Divider()
                        if s.source == .manual {
                            Button("Automatisch erkennen") { model.resetRecurring(s) }
                        }
                        Button("Nicht wiederkehrend", role: .destructive) { model.ignoreRecurring(s) }
                    }
                } label: {
                    Text(series == nil ? "Markieren" : "Ändern")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if let s = series {
                Text("\(s.intervalText) · nächste am \(DateText.medium(s.nextDue))")
                    .font(.callout)
                    .foregroundStyle(Theme.text)
                Text(s.source == .manual
                     ? "Manuell markiert · ca. \(Money.format(s.amountCents))"
                     : "Automatisch erkannt aus \(s.occurrences) Buchungen · ca. \(Money.format(s.amountCents))")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            } else {
                Text("Nicht als wiederkehrend erkannt. Markieren Sie die Buchung, damit sie in den anstehenden Fixkosten erscheint.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .sheet(isPresented: $editingCustom) {
            CustomDatesSheet(initial: series?.interval == .custom ? (series?.intervalText ?? "") : "") { dates in
                model.markRecurring(booking, .custom, customDates: dates)
            }
        }
    }
}

/// Custom recurrence, e.g. "15.03., 15.08." (every year on these days).
struct CustomDatesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let initial: String
    let onSave: ([String]) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Individueller Turnus").font(.headline)
            Text("Tage im Jahr, an denen die Buchung fällig ist, z. B. „15.03., 15.08.“.")
                .font(.callout)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("15.03., 15.08.", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Speichern", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(dates.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
        .onAppear {
            // "Individuell (15.03., 15.08.)" -> "15.03., 15.08."
            if let open = initial.firstIndex(of: "("), let close = initial.lastIndex(of: ")") {
                text = String(initial[initial.index(after: open)..<close])
            }
        }
    }

    private var dates: [String] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func save() {
        guard !dates.isEmpty else { return }
        onSave(dates)
        dismiss()
    }
}

/// "Fixkosten" sheet: what is booked / still due this month, plus all series.
struct RecurringSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Wiederkehrende Buchungen").font(.headline)
                Spacer()
                Button("Fertig") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            List {
                if let m = model.recurringMonth {
                    Section {
                        if m.items.isEmpty {
                            Text("Diesen Monat ist nichts fällig.")
                                .foregroundStyle(Theme.secondary)
                        }
                        ForEach(m.items, id: \.self) { item in
                            monthRow(item)
                        }
                    } header: {
                        Text("Diesen Monat")
                    } footer: {
                        Text("Noch offen: \(Money.format(-m.openExpenseCents)) Ausgaben, \(Money.format(m.openIncomeCents)) Einnahmen · bereits gebucht: \(Money.format(-m.bookedExpenseCents))")
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                    }
                }
                Section {
                    if model.recurring.isEmpty {
                        Text("Noch keine wiederkehrenden Buchungen erkannt. Sie können eine Buchung in der Detailansicht als wiederkehrend markieren.")
                            .foregroundStyle(Theme.secondary)
                    }
                    ForEach(model.recurring, id: \.seriesKey) { s in
                        seriesRow(s)
                    }
                } header: {
                    Text("Alle (\(model.recurring.count))")
                }
            }
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    private func monthRow(_ item: RecurringMonthItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.booked ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(item.booked ? Theme.inflow : Theme.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.series.name).lineLimit(1)
                Text(item.booked ? "Gebucht am \(DateText.medium(item.dueDate))" : "Fällig am \(DateText.medium(item.dueDate))")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            Text(Money.format(item.amountCents))
                .monospacedDigit()
                .foregroundStyle(item.amountCents < 0 ? Theme.outflow : Theme.inflow)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let id = item.bookingId { model.selectedBookingID = id; dismiss() }
        }
    }

    private func seriesRow(_ s: RecurringSeries) -> some View {
        HStack(spacing: 10) {
            Image(systemName: s.source == .manual ? "hand.point.up.left" : "sparkles")
                .foregroundStyle(Theme.tertiary)
                .help(s.source == .manual ? "Manuell markiert" : "Automatisch erkannt")
            VStack(alignment: .leading, spacing: 1) {
                Text(s.name).lineLimit(1)
                Text("\(s.intervalText) · nächste am \(DateText.medium(s.nextDue))")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            Text(Money.format(s.amountCents))
                .monospacedDigit()
                .foregroundStyle(s.amountCents < 0 ? Theme.outflow : Theme.inflow)
            Menu {
                if s.source == .manual {
                    Button("Automatisch erkennen") { model.resetRecurring(s) }
                }
                Button("Nicht wiederkehrend", role: .destructive) { model.ignoreRecurring(s) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}
