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

/// Root row of the account tree: opens the overview of all accounts, folds
/// every group away and shows the total per currency.
struct AllAccountsRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hasAccounts = !model.allAccounts.isEmpty
        let open = model.showsAccountTree
        HStack(spacing: 6) {
            if hasAccounts {
                Button {
                    withAnimation(Motion.animation(.easeInOut(duration: 0.15))) { model.allAccountsCollapsed.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .appFont(.caption, weight: .bold)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 12, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(open ? "Alle Konten einklappen" : "Alle Konten ausklappen")
                .accessibilityValue(open ? "Ausgeklappt" : "Eingeklappt")
            }
            Image(systemName: "square.grid.2x2").foregroundStyle(Theme.secondary).frame(width: 20)
            Text("Alle Konten").fontWeight(.medium).lineLimit(1).appDefaultFont()
            Spacer(minLength: 4)
            ForEach(AllAccountsTotal.totals(of: model.allAccounts), id: \.currency) { total in
                Text(Money.format(total.cents, currency: total.currency))
                    .sensitive()
                    .appFont(.callout, weight: .semibold, monospacedDigit: true)
                    .foregroundStyle(total.cents < 0 ? Theme.negative : Theme.secondary)
                    .lineLimit(1)
                    // amounts never truncate; the name gives way (#343)
                    .fixedSize()
            }
        }
    }
}
