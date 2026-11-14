import Foundation
import GiroCrabCore

/// One card of „Neue Umsätze“ (GitHub #352): an account and its unreviewed bookings.
struct NewBookingsSection: Identifiable, Equatable {
    let accountID: Int64
    /// nil for a booking whose account the sidebar does not list (archived, hidden).
    let account: Account?
    let title: String
    let bookings: [Booking]
    var id: Int64 { accountID }

    /// Sum of the card's pending bookings ("Vorgemerkt").
    var pendingCents: Int64 { bookings.filter(\.isPending).reduce(0) { $0 + $1.amountCents } }
}

enum NewBookings {
    /// Groups bookings by account: known accounts in sidebar order, then unknown ones
    /// in the order they first appear. Each section keeps the bookings' order.
    /// Checked bookings are left out: the previous list may still be on screen
    /// while the page loads in the background.
    static func sections(bookings: [Booking], accounts: [Account]) -> [NewBookingsSection] {
        let bookings = bookings.filter { !$0.checked }
        let byAccount = Dictionary(grouping: bookings, by: \.accountId)
        var sections = accounts.compactMap { account in
            byAccount[account.id].map { NewBookingsSection(accountID: account.id, account: account, title: account.name, bookings: $0) }
        }
        let known = Set(accounts.map(\.id))
        var seen = Set<Int64>()
        for b in bookings where !known.contains(b.accountId) && seen.insert(b.accountId).inserted {
            sections.append(NewBookingsSection(accountID: b.accountId, account: nil, title: b.accountName, bookings: byAccount[b.accountId] ?? []))
        }
        return sections
    }
}
