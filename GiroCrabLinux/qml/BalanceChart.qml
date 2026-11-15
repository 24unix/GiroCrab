import QtQuick

// BalanceHeaderView.swift › BalanceChart (line style): balance over the
// selected period, soft area fill, date labels; a click jumps to the day.
Item {
    id: chart
    property var points: []
    signal selectDay(string day)
    property int hovered: -1

    readonly property var stats: {
        let lo = Infinity, hi = -Infinity
        for (const p of points) { lo = Math.min(lo, p.balance_cents); hi = Math.max(hi, p.balance_cents) }
        // BalanceHeaderView.swift: 15 % room above and below (at least 1 €)
        const pad = Math.max((hi - lo) * 0.15, 100)
        return { lo: lo - pad, hi: hi + pad }
    }
    readonly property int axisHeight: 16
    function xAt(i) { return points.length < 2 ? 0 : i / (points.length - 1) * width }
    function yAt(c) { const h = height - axisHeight - 4; return 2 + h - (c - stats.lo) / (stats.hi - stats.lo) * h }

    /// Points actually drawn: with more days than pixels the balance is averaged per
    /// ~2 px bucket (first and last value kept), so 17 years of daily balances stay
    /// smooth and cheap. Each entry: { x, y } in pixels.
    readonly property var drawn: {
        const n = points.length
        if (n < 2 || width <= 0) return []
        const buckets = Math.max(2, Math.floor(width / 2))
        const out = []
        if (n <= buckets) {
            for (let i = 0; i < n; i++) out.push({ x: xAt(i), y: yAt(points[i].balance_cents) })
            return out
        }
        out.push({ x: 0, y: yAt(points[0].balance_cents) })
        for (let b = 1; b < buckets - 1; b++) {
            const from = Math.floor(b * n / buckets), to = Math.floor((b + 1) * n / buckets)
            let sum = 0
            for (let i = from; i < to; i++) sum += points[i].balance_cents
            out.push({ x: xAt((from + to - 1) / 2), y: yAt(sum / Math.max(1, to - from)) })
        }
        out.push({ x: width, y: yAt(points[n - 1].balance_cents) })
        return out
    }
    /// Monotone cubic curve through `pts` (Fritsch–Carlson, like Swift Charts'
    /// .interpolationMethod(.monotone)): smooth, but never overshoots the values.
    function traceMonotone(ctx, pts) {
        const n = pts.length
        ctx.moveTo(pts[0].x, pts[0].y)
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

    onDrawnChanged: canvas.requestPaint()
    onHoveredChanged: canvas.requestPaint()
    Connections { target: Theme; function onDarkChanged() { canvas.requestPaint() } }

    Canvas {
        id: canvas
        anchors.fill: parent
        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            const pts = chart.points, line = chart.drawn
            if (pts.length < 2 || line.length < 2) return
            const base = chart.height - chart.axisHeight
            // RuleMark per new year (dashed), BalanceBuckets.yearStarts
            ctx.save()
            ctx.strokeStyle = Theme.withAlpha(Theme.tertiary, 0.5); ctx.lineWidth = 1
            ctx.setLineDash([2, 3])
            for (let i = 1; i < pts.length; i++) {
                if (pts[i].date.slice(0, 4) !== pts[i - 1].date.slice(0, 4)) {
                    const x = Math.round(chart.xAt(i)) + 0.5
                    ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, base); ctx.stroke()
                }
            }
            ctx.restore()
            ctx.beginPath()
            chart.traceMonotone(ctx, line)
            ctx.lineTo(chart.width, base); ctx.lineTo(0, base); ctx.closePath()
            const g = ctx.createLinearGradient(0, 0, 0, base)
            g.addColorStop(0, Theme.withAlpha(Theme.accent, 0.14)); g.addColorStop(1, Theme.withAlpha(Theme.accent, 0.01))
            ctx.fillStyle = g; ctx.fill()
            ctx.beginPath()
            chart.traceMonotone(ctx, line)
            ctx.strokeStyle = Theme.withAlpha(Theme.accent, 0.8); ctx.lineWidth = 1.5; ctx.stroke()
            if (chart.hovered >= 0) {
                const x = chart.xAt(chart.hovered)
                ctx.strokeStyle = Theme.withAlpha(Theme.secondary, 0.5); ctx.lineWidth = 1
                ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, base); ctx.stroke()
                ctx.fillStyle = Theme.accent
                ctx.beginPath(); ctx.arc(x, chart.yAt(pts[chart.hovered].balance_cents), 3.5, 0, 2 * Math.PI); ctx.fill()
            }
        }
    }
    // x-axis like BalanceHeaderView.swift › xAxis: marks on calendar boundaries –
    // years (> 400 days), days (< 62 days) or months, thinned so labels never crowd.
    function axisStride(units, labelWidth, steps) {
        const fit = Math.max(width / labelWidth, 1)
        for (const s of steps) if (units / s <= fit) return s
        return steps[steps.length - 1]
    }
    readonly property var axisMarks: {
        const n = points.length
        if (n < 2 || width <= 0) return []
        const first = Fmt.date(points[0].date), last = Fmt.date(points[n - 1].date)
        const span = (last - first) / 86400000
        const marks = []
        if (span > 400) {
            const every = axisStride(span / 365.25, 64, [1, 2, 5, 10, 20])
            for (let i = 1; i < n; i++) {
                const y = Number(points[i].date.slice(0, 4))
                if (y !== Number(points[i - 1].date.slice(0, 4)) && y % every === 0) marks.push({ i: i, text: String(y) })
            }
        } else if (span < 62) {
            const every = axisStride(span, 64, [7, 14, 28])
            for (let i = 0; i < n; i += every) marks.push({ i: i, text: Fmt.shortDay(Fmt.date(points[i].date)) })
        } else {
            const every = axisStride(span / 30.44, 44, [1, 2, 3, 6])
            for (let i = 1; i < n; i++) {
                const m = Number(points[i].date.slice(5, 7))
                if (m !== Number(points[i - 1].date.slice(5, 7)) && (m - 1) % every === 0)
                    marks.push({ i: i, text: Qt.locale().monthName(m - 1, Locale.ShortFormat) })
            }
        }
        return marks
    }
    Repeater {
        model: chart.axisMarks
        Text {
            required property var modelData
            text: modelData.text
            font.pixelSize: Theme.caption; color: Theme.tertiary
            y: chart.height - chart.axisHeight + 2
            x: Math.max(0, Math.min(chart.width - width, chart.xAt(modelData.i) - width / 2))
        }
    }
    Rectangle {
        visible: chart.hovered >= 0
        color: Theme.card; border.color: Theme.border; radius: 6
        width: tip.implicitWidth + 12; height: tip.implicitHeight + 8
        x: Math.max(0, Math.min(chart.width - width, chart.xAt(chart.hovered) + 8)); y: 0
        Text { id: tip; anchors.centerIn: parent; font.pixelSize: Theme.caption; color: Theme.text
               text: chart.hovered >= 0 ? Fmt.medium(chart.points[chart.hovered].date) + "  " + Fmt.money(chart.points[chart.hovered].balance_cents) : "" }
    }
    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        function index(x) { return Math.max(0, Math.min(chart.points.length - 1, Math.round(x / Math.max(1, chart.width) * (chart.points.length - 1)))) }
        onPositionChanged: m => chart.hovered = chart.points.length ? index(m.x) : -1
        onExited: chart.hovered = -1
        onClicked: m => { if (chart.points.length) chart.selectDay(chart.points[index(m.x)].date) }
    }
}
