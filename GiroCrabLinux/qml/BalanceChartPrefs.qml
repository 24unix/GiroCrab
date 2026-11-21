pragma Singleton
import QtQuick
import QtCore

// BalanceBars.swift: look of the chart in the header (GitHub #203, #634). The line shows
// every day, bars the average balance per day, month or year, the pie shares (a category's
// subcategories, an account's expenses by category). Stored like the Mac's UserDefaults
// `chart.balanceStyle` / `chart.balanceBarUnit` (GiroCrab.conf, section [chart]); whether the
// chart shows at all is a separate fold (`headerChartCollapsed`, ViewLayout.headerChartCollapsedKey).
QtObject {
    id: prefs

    property Settings store: Settings {
        category: "chart"
        property string balanceStyle: "line"
        property string balanceBarUnit: "auto"
    }
    /// `@AppStorage(ViewLayout.headerChartCollapsedKey)`: top level like the other ViewLayout keys.
    property Settings layout: Settings {
        property bool headerChartCollapsed: false
    }

    // BalanceChartStyle (title, systemImage)
    readonly property var styles: [{ id: "line", title: qsTr("Linie"), symbol: "chart.xyaxis.line" },
                                   { id: "bars", title: qsTr("Balken"), symbol: "chart.bar.xaxis" },
                                   { id: "pie", title: qsTr("Kreis"), symbol: "chart.pie" }]
    readonly property string style: styles.some(s => s.id === store.balanceStyle) ? store.balanceStyle : "line"
    function setStyle(id) { store.balanceStyle = id }

    /// HeaderChartControls: „Ausgeblendet“ folds only the chart and keeps the chosen type.
    readonly property bool collapsed: layout.headerChartCollapsed
    function setCollapsed(on) { layout.headerChartCollapsed = on }

    // BalanceBarUnit (titles); `units` = balanceCases (accounts, groups)
    readonly property var units: [{ id: "auto", title: qsTr("Automatisch") }, { id: "day", title: qsTr("Tage") },
                                  { id: "month", title: qsTr("Monate") }, { id: "year", title: qsTr("Jahre") }]
    /// BalanceBarUnit.categoryCases: quarters only exist for category sums (#634).
    readonly property var categoryUnits: [{ id: "day", title: qsTr("Tage") }, { id: "month", title: qsTr("Monate") },
                                          { id: "quarter", title: qsTr("Quartale") }, { id: "year", title: qsTr("Jahre") }]
    function unitTitle(id) {
        const u = units.concat(categoryUnits).find(u => u.id === id)
        return u ? u.title : ""
    }
    readonly property string barUnit: units.some(u => u.id === store.balanceBarUnit) ? store.balanceBarUnit : "auto"
    function setBarUnit(id) { store.balanceBarUnit = id }

    /// AppModel.swift › categoryBarUnit (#557): not stored; "auto" follows the global setting.
    property string categoryBarUnit: "auto"
    /// AppModel+Loading.swift › effectiveCategoryBarUnit: own choice (also quarters, #634),
    /// else the global setting, else months.
    readonly property string effectiveCategoryBarUnit: categoryBarUnit !== "auto" ? categoryBarUnit
        : barUnit === "auto" ? "month" : barUnit
    /// BalanceBarUnit.keyLength: characters of the ISO date that identify one bar; quarters
    /// are loaded as months and grouped in the chart.
    readonly property int categoryKeyLength: effectiveCategoryBarUnit === "year" ? 4 : effectiveCategoryBarUnit === "day" ? 10 : 7
    /// BarUnitMenu on the category chart: `model.categoryBarUnit = $0; model.reloadCategoryHistory()`
    function setCategoryBarUnit(id) {
        if (categoryBarUnit === id) return
        categoryBarUnit = id
        reloadCategoryChart()
    }
    // the global choice changes the category chart while it follows it
    onBarUnitChanged: if (categoryBarUnit === "auto") reloadCategoryChart()
    /// A running selection load brings the category chart with the new unit (its older result
    /// is dropped); without one the chart loads on its own (AppModel.reloadCategoryHistory).
    function reloadCategoryChart() {
        if (!AppModel.selectionLoadTakes(null)) AppModel.reloadCategoryHistory()
    }

    /// BalanceBarUnit.resolved(dayCount:): days up to two months, months up to six years, years beyond.
    function resolvedUnit(dayCount) {
        if (barUnit !== "auto") return barUnit
        if (dayCount <= 62) return "day"
        // ~72 monthly bars still read as bars; beyond that they turn into a barcode
        return dayCount <= 6 * 366 ? "month" : "year"
    }

    /// BalanceBuckets.make: groups the daily balances (`date` yyyy-MM-dd, oldest first) by
    /// the ISO prefix of the unit. Each bucket: { start (ISO), last (ISO), average, closing, days }.
    function buckets(points, unit) {
        const keyLength = unit === "year" ? 4 : unit === "month" ? 7 : 10
        const startSuffix = keyLength === 4 ? "-01-01" : keyLength === 7 ? "-01" : ""
        const out = []
        let key = "", sum = 0, group = []
        function flush() {
            const n = group.length
            // rounded half away from zero, so a month at -0,5 ct does not show as +0
            const avg = sum >= 0 ? Math.floor((sum + Math.floor(n / 2)) / n) : -Math.floor((-sum + Math.floor(n / 2)) / n)
            out.push({ start: group[0].date.slice(0, keyLength) + startSuffix, last: group[n - 1].date,
                       average: avg, closing: group[n - 1].balance_cents, days: n })
        }
        for (const p of points) {
            const k = p.date.slice(0, keyLength)
            if (k !== key && group.length) { flush(); group = []; sum = 0 }
            key = k
            group.push(p)
            sum += p.balance_cents
        }
        if (group.length) flush()
        return out
    }
}
