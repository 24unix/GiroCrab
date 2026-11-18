import SwiftUI

/// Display settings of the booking rows, read from the defaults once per window
/// (`.listSettingsEnvironment()` at the main window's root) and handed down the environment.
///
/// Row views must not hold an `@AppStorage` of their own: SwiftUI never finds such a view
/// equal to its previous value, so every visible row re-ran its body whenever the list
/// above it did (a click in the sidebar rebuilt all of them before the new selection had
/// even loaded), and every row that scrolled in set up its own defaults observers.
extension EnvironmentValues {
    @Entry var bookingDensity: BookingDensity = .standard
    @Entry var negativeAmountStyle: NegativeAmountStyle = .neutral
    /// Accounts whose booking rows hide the category chip (GitHub #336).
    @Entry var hiddenCategoryChipAccounts: Set<Int64> = []
}

extension View {
    /// Scene root of every window that shows booking rows.
    func listSettingsEnvironment() -> some View {
        modifier(ListSettingsEnvironment())
    }
}

private struct ListSettingsEnvironment: ViewModifier {
    @AppStorage(BookingDensity.defaultsKey) private var density: BookingDensity = .standard
    @AppStorage(NegativeAmountStyle.defaultsKey) private var negativeStyle: NegativeAmountStyle = .neutral
    @AppStorage(ViewLayout.hiddenCategoryChipAccountsKey) private var hiddenCategoryChipAccounts = ""

    func body(content: Content) -> some View {
        content
            .environment(\.bookingDensity, density)
            .environment(\.negativeAmountStyle, negativeStyle)
            .environment(\.hiddenCategoryChipAccounts, ViewLayout.hiddenCategoryChipAccounts(raw: hiddenCategoryChipAccounts))
    }
}
