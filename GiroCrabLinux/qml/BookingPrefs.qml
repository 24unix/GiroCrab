pragma Singleton
import QtQuick
import QtCore

// Local presentation preferences of the booking list, stored like the Mac's UserDefaults in
// GiroCrab.conf (never in the vault): NegativeAmountStyle.swift (`negativeAmountStyle`),
// BookingDensity.swift (`bookingDensity`) and ViewLayout.swift (`hiddenCategoryChipAccounts`).
QtObject {
    id: prefs

    property Settings store: Settings {
        property string negativeAmountStyle: "neutral"
        property string bookingDensity: "standard"
        property string hiddenCategoryChipAccounts: ""
    }

    // MARK: NegativeAmountStyle.swift (#218, #571)
    /// Colour scheme of amounts in the booking list; the minus (and plus) sign always stays,
    /// so the direction never depends on colour alone.
    readonly property var negativeStyles: [
        { id: "neutral", title: qsTr("Neutral") },
        { id: "red", title: qsTr("Rot") },
        { id: "contrast", title: qsTr("Kontraststark") }]
    /// The stored choice; unknown or missing values fall back to "neutral".
    readonly property string negativeStyle: negativeStyles.some(s => s.id === store.negativeAmountStyle)
                                            ? store.negativeAmountStyle : "neutral"
    function setNegativeStyle(id) { store.negativeAmountStyle = id }
    // Orange vs. blue stays distinguishable for red-green colour blindness.
    readonly property color contrastNegative: Theme.c("#9A3412", "#FB923C")
    readonly property color contrastPositive: Theme.c("#1D4ED8", "#60A5FA")
    readonly property color contrastPositiveBadge: Theme.c("#EFF6FF", "#172554")
    /// Colour of negative amounts.
    readonly property color negativeColor: negativeStyle === "red" ? Theme.negative
                                         : negativeStyle === "contrast" ? contrastNegative : Theme.outflow
    /// Text colour of positive amounts (on `positiveBadge`).
    readonly property color positiveColor: negativeStyle === "contrast" ? contrastPositive : Theme.inflow
    readonly property color positiveBadge: negativeStyle === "contrast" ? contrastPositiveBadge : Theme.inflowBadge

    // MARK: BookingDensity.swift (#542)
    readonly property var densities: [
        { id: "compact", title: qsTr("Kompakt") },
        { id: "standard", title: qsTr("Standard") },
        { id: "spacious", title: qsTr("Großzügig") }]
    /// The stored choice; unknown values count as "standard".
    readonly property string density: densities.some(d => d.id === store.bookingDensity) ? store.bookingDensity : "standard"
    function setDensity(id) { store.bookingDensity = id }

    // MARK: ViewLayout.swift › hiddenCategoryChipAccounts (#336, #604)
    /// Accounts that hide the category chip in booking rows: { id: true }.
    readonly property var hiddenCategoryChipIDs: {
        const out = {}
        for (const s of store.hiddenCategoryChipAccounts.split(",")) if (s !== "" && !isNaN(Number(s))) out[Number(s)] = true
        return out
    }
    function showsCategoryChip(accountID) { return !hiddenCategoryChipIDs[accountID] }
    function setShowsCategoryChip(show, accountID) {
        const ids = Object.assign({}, hiddenCategoryChipIDs)
        if (show) delete ids[accountID]; else ids[accountID] = true
        store.hiddenCategoryChipAccounts = Object.keys(ids).map(Number).sort((a, b) => a - b).join(",")
    }
}
