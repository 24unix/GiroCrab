import QtQuick

// CategorySumChart.swift: day, month, quarter or year sums of the selected category (incl.
// subcategories) above its bookings (GitHub #502, #557, #634). Pure expense categories are
// drawn upwards (magnitude), mixed ones signed. Bars or a line, following the header's chart
// type; the bar width comes from „Balken je“ below the chart or the right-click menu
// (BalanceChartPrefs.effectiveCategoryBarUnit). Hovering a bar shows its period and sum.
Item {
    id: chart
    /// [CategoryPeriodSum] from `category_history_by_unit` (`yyyy`, `yyyy-MM` or `yyyy-MM-dd`)
    property var sums: []
    property int hovered: -1

    readonly property string unit: BalanceChartPrefs.effectiveCategoryBarUnit
    readonly property bool line: BalanceChartPrefs.style === "line"

    /// Position of a period on the time axis in units of one bar.
    function slotOf(period) {
        const y = Number(period.slice(0, 4))
        if (period.length === 4) return y
        const m = Number(period.slice(5, 7))
        if (period.length === 7) return unit === "quarter" ? y * 4 + Math.floor((m - 1) / 3) : y * 12 + m - 1
        return Math.round(Date.UTC(y, m - 1, Number(period.slice(8, 10))) / 86400000)
    }
    /// CategorySumChart.quarters: month sums (`yyyy-MM`, oldest first) added up per quarter,
    /// keyed by its first month.
    function quarters(months) {
        const out = []
        for (const s of months) {
            if (s.period.length !== 7) continue
            const month = Number(s.period.slice(5, 7))
            if (month < 1 || month > 12) continue
            const key = s.period.slice(0, 4) + "-" + String(Math.floor((month - 1) / 3) * 3 + 1).padStart(2, "0")
            if (out.length && out[out.length - 1].period === key) out[out.length - 1].cents += s.cents
            else out.push({ period: key, cents: s.cents })
        }
        return out
    }
    /// CategorySumChart.bars: one entry per period with bookings; `slot` counts bars from the
    /// first one, so periods without bookings stay empty on the time axis.
    readonly property var bars: {
        const list = unit === "quarter" ? quarters(sums) : sums
        const out = []
        let first = null
        for (const s of list) {
            if (!Number(s.period.slice(0, 4))) continue
            const index = slotOf(s.period)
            if (first === null) first = index
            out.push({ period: s.period, slot: index - first, cents: s.cents })
        }
        return out
    }
    readonly property int slots: bars.length ? bars[bars.length - 1].slot + 1 : 0
    /// CategorySumChart.flipsSign: an expense-only series shows positive heights.
    readonly property bool flip: bars.length > 0 && bars.every(b => b.cents <= 0)
    function value(b) { return (flip ? -b.cents : b.cents) / 100 }

    /// Value axis with "nice" steps like Swift Charts' automatic marks (0 always included).
    readonly property var axis: {
        let lo = 0, hi = 0
        for (const b of bars) { lo = Math.min(lo, value(b)); hi = Math.max(hi, value(b)) }
        if (lo === hi) hi = lo + 1
        const raw = (hi - lo) / 3
        const mag = Math.pow(10, Math.floor(Math.log10(raw)))
        const step = [1, 2, 2.5, 5, 10].map(f => f * mag).find(s => s >= raw)
        const top = Math.ceil(hi / step) * step, bottom = Math.floor(lo / step) * step
        const ticks = []
        for (let v = bottom; v <= top + step / 2; v += step) ticks.push(Math.round(v * 100) / 100)
        return { lo: bottom, hi: top, ticks: ticks }
    }
    readonly property int axisHeight: Theme.scaled(16)   // holds a caption2 label
    /// Room for the trailing value labels.
    readonly property real labelWidth: {
        let w = 0
        for (const v of axis.ticks) w = Math.max(w, metrics.advanceWidth(tickText(v)))
        return Math.ceil(w) + 6
    }
    readonly property real plotWidth: Math.max(0, width - labelWidth)
    readonly property real plotHeight: Math.max(1, height - axisHeight - 4)
    function yAt(v) { return 2 + plotHeight - (v - axis.lo) / (axis.hi - axis.lo) * plotHeight }
    function slotX(slot) { return slots ? slot * plotWidth / slots : 0 }
    function tickText(v) { return Number(v).toLocaleCurrencyString(Fmt.locale, Fmt.currencySymbol("EUR")).replace(/[.,]00(?=\D*$)/, "") }
    FontMetrics { id: metrics; font.pixelSize: Theme.caption2 }

    /// The first day of a period as a Date.
    function startDate(period) {
        return Fmt.date(period.length === 4 ? period + "-01-01" : period.length === 7 ? period + "-01" : period)
    }
    /// CategorySumChart.tooltipFormat: "2026", "Q1 2026", "März 2026", "3. März 2026".
    function tooltipText(period) {
        const d = startDate(period)
        if (!d) return period
        switch (unit) {
        case "year": return String(d.getFullYear())
        case "quarter": return "Q" + (Math.floor(d.getMonth() / 3) + 1) + " " + d.getFullYear()
        case "day": return d.toLocaleDateString(Fmt.locale, Fmt.pattern("d. MMM yyyy"))
        default: return d.toLocaleDateString(Fmt.locale, "MMMM yyyy")
        }
    }
    /// CategorySumChart.axisFormat: "2026", "Q1 26", "Mär. 26", "3. März".
    function axisText(period) {
        const d = startDate(period)
        if (!d) return period
        switch (unit) {
        case "year": return String(d.getFullYear())
        case "quarter": return "Q" + (Math.floor(d.getMonth() / 3) + 1) + " " + String(d.getFullYear() % 100).padStart(2, "0")
        case "day": return Fmt.shortDay(d)
        default: return Fmt.monthLabel(period.slice(0, 7))
        }
    }
    /// Monotone cubic curve through `pts` (BalanceChart.qml, .interpolationMethod(.monotone)).
    function traceMonotone(ctx, pts) {
        const n = pts.length
        ctx.moveTo(pts[0].x, pts[0].y)
        if (n === 1) return
        if (n === 2) { ctx.lineTo(pts[1].x, pts[1].y); return }
        const d = [], m = []
        for (let i = 0; i < n - 1; i++) {
            const dx = pts[i + 1].x - pts[i].x
            d.push(dx === 0 ? 0 : (pts[i + 1].y - pts[i].y) / dx)
        }
        m.push(d[0])
        for (let i = 1; i < n - 1; i++) m.push(d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2)
        m.push(d[n - 2])
        for (let i = 0; i < n - 1; i++) {
            if (d[i] === 0) { m[i] = 0; m[i + 1] = 0; continue }
            const a = m[i] / d[i], b = m[i + 1] / d[i], h = a * a + b * b
            if (h > 9) { const t = 3 / Math.sqrt(h); m[i] = t * a * d[i]; m[i + 1] = t * b * d[i] }
        }
        for (let i = 0; i < n - 1; i++) {
            const dx = (pts[i + 1].x - pts[i].x) / 3
            ctx.bezierCurveTo(pts[i].x + dx, pts[i].y + m[i] * dx, pts[i + 1].x - dx, pts[i + 1].y - m[i + 1] * dx, pts[i + 1].x, pts[i + 1].y)
        }
    }

    onBarsChanged: { hovered = -1; canvas.requestPaint() }
    onLineChanged: canvas.requestPaint()
    onWidthChanged: canvas.requestPaint()
    onHeightChanged: canvas.requestPaint()
    onHoveredChanged: canvas.requestPaint()
    Connections { target: Theme; function onDarkChanged() { canvas.requestPaint() } }

    Canvas {
        id: canvas
        anchors.fill: parent
        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            if (!chart.bars.length || chart.plotWidth <= 0) return
            // AxisGridLine: dashed, tertiary at 45 %
            ctx.save()
            ctx.strokeStyle = Theme.withAlpha(Theme.tertiary, 0.45); ctx.lineWidth = 0.5
            ctx.setLineDash([2, 3])
            for (const v of chart.axis.ticks) {
                const y = Math.round(chart.yAt(v)) + 0.5
                ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(chart.plotWidth, y); ctx.stroke()
            }
            ctx.restore()
            const slotWidth = chart.plotWidth / chart.slots
            if (chart.line) {
                // LineMark through the middle of each period, PointMark per period (larger when hovered)
                const pts = chart.bars.map(b => ({ x: chart.slotX(b.slot + 0.5), y: chart.yAt(chart.value(b)) }))
                if (chart.hovered >= 0) {
                    const x = pts[chart.hovered].x
                    ctx.strokeStyle = Theme.withAlpha(Theme.secondary, 0.45); ctx.lineWidth = 1
                    ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, chart.height - chart.axisHeight); ctx.stroke()
                }
                ctx.beginPath()
                chart.traceMonotone(ctx, pts)
                ctx.strokeStyle = Theme.withAlpha(Theme.accent, 0.8); ctx.lineWidth = 1.5; ctx.stroke()
                chart.bars.forEach((b, i) => {
                    ctx.fillStyle = b.cents < 0 && !chart.flip ? Theme.outflow : Theme.accent
                    ctx.beginPath(); ctx.arc(pts[i].x, pts[i].y, chart.hovered === i ? 3.4 : 1.8, 0, 2 * Math.PI); ctx.fill()
                })
                return
            }
            // RectangleMark with a gap of 12 % of the period on each side
            const barWidth = Math.max(1, slotWidth * 0.76)
            const zero = chart.yAt(0)
            chart.bars.forEach((b, i) => {
                const v = chart.value(b)
                // expense-only: accent; mixed: outflow below zero, inflow above
                const tint = b.cents < 0 && !chart.flip ? Theme.outflow : (b.cents < 0 ? Theme.accent : Theme.inflow)
                ctx.fillStyle = Theme.withAlpha(tint, chart.hovered < 0 || chart.hovered === i ? 0.85 : 0.35)
                const x = chart.slotX(b.slot) + (slotWidth - barWidth) / 2
                const y = chart.yAt(v)
                const top = Math.min(y, zero), h = Math.max(1, Math.abs(zero - y))
                const r = Math.min(1.5, barWidth / 2, h / 2)
                ctx.beginPath()
                ctx.moveTo(x + r, top); ctx.lineTo(x + barWidth - r, top)
                ctx.arcTo(x + barWidth, top, x + barWidth, top + r, r)
                ctx.lineTo(x + barWidth, top + h - r)
                ctx.arcTo(x + barWidth, top + h, x + barWidth - r, top + h, r)
                ctx.lineTo(x + r, top + h)
                ctx.arcTo(x, top + h, x, top + h - r, r)
                ctx.lineTo(x, top + r)
                ctx.arcTo(x, top, x + r, top, r)
                ctx.fill()
            })
        }
    }
    // chartYAxis: trailing value labels (currency, no decimals)
    Repeater {
        model: chart.bars.length ? chart.axis.ticks : []
        Text {
            required property var modelData
            text: chart.tickText(modelData)
            font.pixelSize: Theme.caption2; font.features: { "tnum": 1 }; color: Theme.tertiary
            x: chart.plotWidth + 4
            y: Math.max(0, Math.min(chart.height - chart.axisHeight - height, chart.yAt(modelData) - height / 2))
            Sensitive { amounts: true }
        }
    }
    // chartXAxis: CategorySumChart.axisDates – at most six labels, one per shown bar,
    // centred under it
    Repeater {
        model: {
            const n = chart.bars.length
            if (!n) return []
            const every = Math.max(1, Math.ceil(n / 6))
            const out = []
            for (let i = 0; i < n; i += every) out.push({ slot: chart.bars[i].slot, text: chart.axisText(chart.bars[i].period) })
            return out
        }
        Text {
            required property var modelData
            text: modelData.text
            font.pixelSize: Theme.caption2; color: Theme.tertiary
            y: chart.height - chart.axisHeight + 2
            x: Math.max(0, Math.min(chart.plotWidth - width, chart.slotX(modelData.slot + 0.5) - width / 2))
        }
    }
    // Annotation of the hovered bar: its period, the sum
    Rectangle {
        visible: chart.hovered >= 0
        readonly property var bar: chart.hovered >= 0 ? chart.bars[chart.hovered] : null
        color: Theme.card; border.color: Theme.border; radius: 6
        width: tip.implicitWidth + 14; height: tip.implicitHeight + 8
        x: bar ? Math.max(0, Math.min(chart.plotWidth - width, chart.slotX(bar.slot + 0.5) - width / 2)) : 0
        y: 0
        Column {
            id: tip
            anchors.centerIn: parent
            spacing: 1
            Text { anchors.horizontalCenter: parent.horizontalCenter; font.pixelSize: Theme.caption2; color: Theme.secondary
                   text: parent.parent.bar ? chart.tooltipText(parent.parent.bar.period) : "" }
            Text { anchors.horizontalCenter: parent.horizontalCenter; font.pixelSize: Theme.caption; font.weight: Font.DemiBold; font.features: { "tnum": 1 }
                   color: parent.parent.bar && parent.parent.bar.cents < 0 ? Theme.outflow : Theme.text
                   text: parent.parent.bar ? Fmt.money(parent.parent.bar.cents) : ""
                   Sensitive { amounts: true } }
        }
    }
    // CategorySumChart.swift › Descriptor (#571, #674): title, a whole sentence per unit as the
    // summary (flipped bars = expenses), and the hovered bar like the tooltip (no amount while hidden).
    readonly property string accessibleSummary: {
        switch (unit) {
        case "day": return flip ? qsTr("Ausgaben je Tag") : qsTr("Summe je Tag")
        case "quarter": return flip ? qsTr("Ausgaben je Quartal") : qsTr("Summe je Quartal")
        case "year": return flip ? qsTr("Ausgaben je Jahr") : qsTr("Summe je Jahr")
        default: return flip ? qsTr("Ausgaben je Monat") : qsTr("Summe je Monat")
        }
    }
    Accessible.role: Accessible.Chart
    Accessible.name: qsTr("Summen der Kategorie")
    Accessible.description: hovered < 0 || hovered >= bars.length || (AppModel.effectiveRedaction & AppModel.redactAmounts) !== 0
        ? accessibleSummary
        : accessibleSummary + ". " + tooltipText(bars[hovered].period) + ": " + Fmt.money(flip ? -bars[hovered].cents : bars[hovered].cents)
    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.RightButton
        onPositionChanged: m => {
            if (!chart.slots || m.x > chart.plotWidth) { chart.hovered = -1; return }
            const slot = Math.floor(m.x / chart.plotWidth * chart.slots)
            chart.hovered = chart.bars.findIndex(b => b.slot === slot)
        }
        onExited: chart.hovered = -1
        // .contextMenu { ChartStyleInlinePicker(); unitPicker }
        onClicked: styleMenu.popup()
    }
    AppMenu {
        id: styleMenu
        Repeater {
            model: BalanceChartPrefs.styles
            AppMenuItem { required property var modelData; text: modelData.title; checkable: true
                          checked: BalanceChartPrefs.style === modelData.id
                          onTriggered: { checked = Qt.binding(() => BalanceChartPrefs.style === modelData.id); BalanceChartPrefs.setStyle(modelData.id) } }
        }
        AppMenuSeparator {}
        // unitPicker: day / month / quarter / year per bar, right on the chart (#557, #634)
        Repeater {
            model: BalanceChartPrefs.categoryUnits
            AppMenuItem { required property var modelData; text: modelData.title; checkable: true
                          checked: chart.unit === modelData.id
                          onTriggered: { checked = Qt.binding(() => chart.unit === modelData.id); BalanceChartPrefs.setCategoryBarUnit(modelData.id) } }
        }
    }
}
