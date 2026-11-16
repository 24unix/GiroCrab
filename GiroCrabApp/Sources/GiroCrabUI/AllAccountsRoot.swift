import SwiftUI
import GiroCrabCore

extension AppModel {
    static let allAccountsCollapsedKey = "sidebar.allAccountsCollapsed"

    /// Groups and accounts under „Alle Konten“ are listed: the root is open,
    /// or the sidebar search runs (collapse is ignored so matches stay reachable).
    var showsAccountTree: Bool { !allAccountsCollapsed || isSidebarAccountSearching }
}

/// The total balance of „Alle Konten“, one amount per currency.
enum AllAccountsTotal {
    /// Accounts counted in the total (`inTotal`: not archived, not in a group
    /// left out of the total), summed per currency: other currencies first
    /// (alphabetical), euro last, like MoneyMoney.
    static func totals(of accounts: [Account]) -> [(currency: String, cents: Int64)] {
        var sums: [String: Int64] = [:]
        for a in accounts where a.inTotal {
            let code = a.currency.isEmpty ? "EUR" : a.currency.uppercased()
            sums[code, default: 0] += a.balanceCents
        }
        return sums
            .map { (currency: $0.key, cents: $0.value) }
            .sorted { ($0.currency == "EUR" ? 1 : 0, $0.currency) < ($1.currency == "EUR" ? 1 : 0, $1.currency) }
    }
}

/// Header total of the stream: one primary amount in the base currency, the
/// other currencies listed separately (#569) – never mixed into one number.
enum HeaderTotal {
    struct Split: Equatable {
        var currency: String
        var cents: Int64
        var others: [Other]
        struct Other: Equatable { var currency: String; var cents: Int64 }
    }

    /// Primary = EUR, or the single shared currency when no EUR account is
    /// there; others = every further currency (alphabetical).
    static func split(_ items: [(currency: String, cents: Int64)]) -> Split {
        var sums: [String: Int64] = [:]
        for i in items { sums[i.currency.isEmpty ? "EUR" : i.currency.uppercased(), default: 0] += i.cents }
        let primary = sums["EUR"] != nil || sums.count != 1 ? "EUR" : sums.keys.first!
        return Split(
            currency: primary,
            cents: sums[primary] ?? 0,
            others: sums.filter { $0.key != primary }.sorted { $0.key < $1.key }.map { .init(currency: $0.key, cents: $0.value) }
        )
    }
}

/// Root row of the account tree: opens the overview of all accounts, folds
/// every group away and shows the total per currency.
struct AllAccountsRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hasAccounts = !model.allAccounts.isEmpty
        let open = model.showsAccountTree
        HStack(spacing: DisclosureChevron.gap) {
            if hasAccounts {
                Button {
                    withAnimation(Motion.animation(.easeInOut(duration: 0.15))) { model.allAccountsCollapsed.toggle() }
                } label: {
                    DisclosureChevron(open: open)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(open ? "Alle Konten einklappen" : "Alle Konten ausklappen")
                .accessibilityValue(open ? "Ausgeklappt" : "Eingeklappt")
            } else {
                Color.clear.frame(width: DisclosureChevron.width, height: 18) // keeps the icon axis
            }
            Image(systemName: "square.grid.2x2").foregroundStyle(Theme.secondary).frame(width: 20)
            Text("Alle Konten").fontWeight(.medium).lineLimit(1).appDefaultFont()
            Spacer(minLength: 2)
            ForEach(AllAccountsTotal.totals(of: model.allAccounts), id: \.currency) { total in
                Text(Money.format(total.cents, currency: total.currency))
                    .sensitive()
                    .appFont(.footnote, weight: .semibold, monospacedDigit: true)
                    .foregroundStyle(total.cents < 0 ? Theme.negative : Theme.secondary)
                    .lineLimit(1)
                    // amounts never truncate; the name gives way (#343)
                    .fixedSize()
            }
        }
    }
}
