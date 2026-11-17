pragma Singleton
import QtQuick
import QtCore

// BalanceBars.swift: look of the balance history in the header (GitHub #203). The line
// shows every day, bars the average balance per day, month or year. Stored like the Mac's
// UserDefaults `chart.balanceStyle` / `chart.balanceBarUnit` (GiroCrab.conf, section [chart]).
QtObject {
    id: prefs

    property Settings store: Settings {
        category: "chart"
        property string balanceStyle: "line"
        property string balanceBarUnit: "auto"
    }

    // BalanceChartStyle
    readonly property var styles: [{ id: "line", title: qsTr("Linie") }, { id: "bars", title: qsTr("Balken") }]
    readonly property string style: store.balanceStyle === "bars" ? "bars" : "line"
    function setStyle(id) { store.balanceStyle = id }

    // BalanceBarUnit
    readonly property var units: [{ id: "auto", title: qsTr("Automatisch") }, { id: "day", title: qsTr("Tage") },
                                  { id: "month", title: qsTr("Monate") }, { id: "year", title: qsTr("Jahre") }]
    readonly property string barUnit: units.some(u => u.id === store.balanceBarUnit) ? store.balanceBarUnit : "auto"
    function setBarUnit(id) { store.balanceBarUnit = id }

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
