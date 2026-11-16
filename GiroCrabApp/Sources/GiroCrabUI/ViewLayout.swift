import SwiftUI

/// Persisted view-layout switches shared by the View menu, the toolbar and
/// the settings (GitHub #233, #234).
enum ViewLayout {
    /// Charts and analysis cards above the booking list.
    static let statisticsKey = "showStatistics"
    /// Right-hand inspector column.
    static let inspectorKey = "showInspector"
    /// Monthly budgets: the card above the list and „Monatsbudget festlegen …“.
    static let budgetsKey = "showBudgets"
    /// Header card reduced to title, balance and the filter row: no balance
    /// chart, KPIs or loan progress, more room for the bookings (GitHub #358).
    static let compactHeaderKey = "compactHeader"
    /// Cashflow / monthly budget cards folded to a one-line header (GitHub #603).
    static let cashflowCollapsedKey = "cashflowCollapsed"
    static let budgetsCollapsedKey = "budgetsCollapsed"
    /// Header chart folded to its title row; balance, KPIs and filters stay (#634).
    static let headerChartCollapsedKey = "headerChartCollapsed"
    /// Shared card spacing so the three cards above the list line up (GitHub #603).
    static let cardPadding: CGFloat = 12
    static let cardSpacing: CGFloat = 8
    /// Outer gap between the stacked cards above the booking list (demo banner, header, cashflow, budgets, first day).
    static let cardGap: CGFloat = 4
    /// Top/bottom inset of a folded card: one compact row.
    static let collapsedCardVerticalPadding: CGFloat = 4
    static func cardVerticalPadding(collapsed: Bool) -> CGFloat { collapsed ? collapsedCardVerticalPadding : cardPadding }

    /// Budgets show until switched off (Ansicht › Budgets anzeigen).
    static func showsBudgets(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: budgetsKey) as? Bool ?? true
    }

    /// Which cards go above the list where analyses show (overview, or an
    /// account with „Auswertungen“ opened): each follows its own switch, so
    /// the budgets stay when the analyses are off.
    static func cards(statistics: Bool, budgets: Bool) -> (cashflow: Bool, budgets: Bool, any: Bool) {
        (statistics, budgets, statistics || budgets)
    }

    /// The header shows in full until minimised (Ansicht › Kopfbereich minimieren).
    static func compactHeader(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: compactHeaderKey)
    }

    /// Accounts that hide the category chip in booking rows (GitHub #336).
    static let hiddenCategoryChipAccountsKey = "hiddenCategoryChipAccounts"

    static func showsCategoryChip(for accountID: Int64, _ defaults: UserDefaults = .standard) -> Bool {
        let raw = defaults.string(forKey: hiddenCategoryChipAccountsKey) ?? ""
        let hidden = Set(raw.split(separator: ",").compactMap { Int64($0) })
        return !hidden.contains(accountID)
    }

    static func setShowsCategoryChip(_ show: Bool, for accountID: Int64, _ defaults: UserDefaults = .standard) {
        let raw = defaults.string(forKey: hiddenCategoryChipAccountsKey) ?? ""
        var hidden = Set(raw.split(separator: ",").compactMap { Int64($0) })
        if show { hidden.remove(accountID) } else { hidden.insert(accountID) }
        defaults.set(hidden.sorted().map(String.init).joined(separator: ","), forKey: hiddenCategoryChipAccountsKey)
    }
}
