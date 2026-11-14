import SwiftUI
import GiroCrabCore

/// „Neue Umsätze“ (GitHub #352): one card per account with unreviewed bookings,
/// each listing only those. Shown inside `BookingStreamView` in place of the
/// day cards, so toolbar, keyboard, inspector sheet, print and paging are the
/// booking list's own (`currentFilter` asks for unchecked bookings).
struct NewBookingsCards: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sections = model.newBookingSections
        if sections.isEmpty, !model.isLoadingSelection {
            ContentUnavailableView(
                "Keine neuen Umsätze",
                systemImage: "checkmark.circle",
                description: Text("Alle Buchungen sind geprüft.")
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        }
        ForEach(sections) { section in
            NewBookingsCardHeader(section: section)
                .padding(.top, 14)
            ForEach(section.bookings) { b in
                DayCardRow(booking: b, isLast: b.id == section.bookings.last?.id)
                    .id(b.id)
            }
        }
    }
}

/// Top of an account card: signet, name, IBAN · bank, balance and pending sum.
private struct NewBookingsCardHeader: View {
    @Environment(AppModel.self) private var model
    let section: NewBookingsSection

    private var detail: String {
        guard let a = section.account else { return "" }
        let number = a.iban.isEmpty ? a.accountNumber : formatIBAN(a.iban)
        return [number, a.bankName].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                if let a = section.account {
                    AccountSignet(account: a, size: 28, color: model.accountColor(a.id), onSelection: false)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title)
                        .appFont(.headline)
                        .sensitive()
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail)
                            .appFont(.caption)
                            .sensitive()
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if let a = section.account {
                        Text(Money.format(a.balanceCents, currency: a.currency))
                            .appFont(.headline, monospacedDigit: true)
                            .fixedSize() // the name truncates, never the balance (#343)
                            .sensitive()
                            .foregroundStyle(a.balanceCents < 0 ? Theme.negative : Theme.text)
                    }
                    if section.pendingCents != 0 {
                        Text("Vorgemerkt: \(Money.format(section.pendingCents, currency: section.account?.currency ?? "EUR"))")
                            .appFont(.caption, monospacedDigit: true)
                            .fixedSize()
                            .sensitive()
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Rectangle().fill(Theme.border).frame(height: 1)
        }
        .modifier(DayCardSegment(isTop: true, isBottom: false))
    }
}
