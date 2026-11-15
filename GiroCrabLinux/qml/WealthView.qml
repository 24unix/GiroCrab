import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtCore

// WealthView.swift: „Vermögen“ – cash and assets (depots, Sachwerte) at a glance, minus
// liabilities. The scope picker (Alles / Cash / Wertpapiere / Sachwerte) sits in the toolbar
// (Main.qml), like on the Mac.
Rectangle {
    id: wv
    color: Theme.canvas
    readonly property string scope: AppModel.wealthScope
    /// @AppStorage("wealth.includeLiabilities"): credit cards and loans reduce the net worth.
    Settings { id: prefs; category: "wealth"; property bool includeLiabilities: true }
    property int historyDays: 90
    property var history: []
    property var positions: []
    property var income: ({ dividends: 0, fees: 0, taxes: 0 })
    readonly property bool incomeEmpty: income.dividends === 0 && income.fees === 0 && income.taxes === 0

    // MARK: WealthSummary / WealthBucket
    /// Only active EUR accounts that count towards the total; other currencies are a note.
    readonly property var summary: {
        const s = { cash: [], securities: [], tangibles: [], liabilities: [], foreign: 0 }
        void AppModel.tangibleAccountIDs
        for (const a of AppModel.allAccounts) {
            if (a.archived_unix !== null || !a.in_total) continue
            if (a.currency !== "EUR") { s.foreign++; continue }
            s[bucket(a)].push(a)
        }
        const sum = list => list.reduce((t, a) => t + a.balance_cents, 0)
        s.cashCents = sum(s.cash)
        s.securitiesCents = sum(s.securities)
        s.tangiblesCents = sum(s.tangibles)
        s.liabilitiesTotal = sum(s.liabilities)
        s.assetsCents = s.securitiesCents + s.tangiblesCents
        /// Debts: the negative balances of cards and loans.
        s.liabilitiesCents = s.liabilities.reduce((t, a) => t + Math.min(a.balance_cents, 0), 0)
        /// A positive card balance (credit) is an asset.
        s.creditCents = s.liabilities.reduce((t, a) => t + Math.max(a.balance_cents, 0), 0)
        s.grossCents = s.cashCents + s.assetsCents + s.creditCents
        return s
    }
    /// WealthBucket.bucket(for:tangible:): Sachwerte are depot-like accounts, but no securities.
    function bucket(a) {
        switch (a.kind) {
        case "Brokerage": return AppModel.isTangible(a.id) ? "tangibles" : "securities"
        case "CreditCard": case "Loan": return "liabilities"
        default: return "cash"
        }
    }
    function netCents(s) { return s.grossCents + (prefs.includeLiabilities ? s.liabilitiesCents : 0) }

    // MARK: loading (.task(id:))
    readonly property string syncStamp: AppModel.connections.map(c => c.id + ":" + (c.last_sync_unix || 0)).join(",")
    /// Positions and transactions can change while the depot total stays the same.
    readonly property string positionsKey: summary.securities.map(a => a.id + ":" + a.balance_cents + ":" + a.balance_date).join(",") + "|" + syncStamp
    /// Late bookings can change the history while today's balance stays the same.
    readonly property string historyKey: summary.cash.map(a => a.id + ":" + a.balance_cents + ":" + a.transaction_count + ":" + a.balance_date).join(",")
                                         + "|" + historyDays + "|" + syncStamp
    onPositionsKeyChanged: Qt.callLater(loadPositions)
    onHistoryKeyChanged: Qt.callLater(loadHistory)
    Component.onCompleted: { loadPositions(); loadHistory() }
    property int historyGeneration: 0
    property int positionsGeneration: 0

    function loadHistory() {
        const ids = summary.cash.map(a => a.id)
        const gen = ++historyGeneration
        if (!ids.length) { history = []; return }
        AppModel.coreAsync("balance_history", { account_ids: ids, days: historyDays }, pts => {
            if (gen === historyGeneration) history = pts
        }, () => {})
    }
    function loadPositions() {
        const ids = summary.securities.map(a => a.id)
        const gen = ++positionsGeneration
        const since = new Date(); since.setFullYear(since.getFullYear() - 1)
        const sinceISO = Fmt.iso(since)
        Promise.all([
            Promise.all(ids.map(id => AppModel.corePromise("list_holdings", { account_id: id }))),
            Promise.all(ids.map(id => AppModel.corePromise("list_security_transactions", { account_id: id })))
        ]).then(r => {
            if (gen !== positionsGeneration) return
            positions = aggregate(r[0])
            income = makeIncome([].concat(...r[1]), sinceISO)
        }, () => {})
    }

    // MARK: WealthPosition.aggregate
    function addOpt(a, b) { return a === null ? b : b === null ? a : a + b }
    /// HoldingsCard.calculatedGain: cost = quantity × purchase price.
    function calculatedGain(h) {
        if (!(h.quantity > 0) || h.purchase_price_cents <= 0 || h.value_cents < 0) return null
        const cost = Math.round(h.quantity * h.purchase_price_cents)
        if (!(cost >= 1)) return null
        return h.value_cents - cost
    }
    function aggregate(perDepot) {
        const byKey = {}
        for (const depot of perDepot) for (const h of depot) {
            const key = h.isin ? h.isin : (h.wkn ? h.wkn : h.name)
            const day = h.prev_day_value_cents !== null && h.prev_day_value_cents !== undefined ? h.value_cents - h.prev_day_value_cents : null
            const reported = h.profit_loss_purchase_cents
            const gain = reported !== null && reported !== undefined ? reported : calculatedGain(h)
            const p = byKey[key]
            if (p) {
                p.quantity += h.quantity; p.valueCents += h.value_cents
                p.dayChangeCents = addOpt(p.dayChangeCents, day); p.gainCents = addOpt(p.gainCents, gain)
                p.lines += 1; p.dayLines += day === null ? 0 : 1; p.gainLines += gain === null ? 0 : 1
            } else {
                byKey[key] = { id: key, name: h.name || key, quantity: h.quantity, valueCents: h.value_cents,
                               dayChangeCents: day, gainCents: gain, lines: 1, dayLines: day === null ? 0 : 1, gainLines: gain === null ? 0 : 1 }
            }
        }
        return Object.values(byKey).sort((a, b) => a.valueCents !== b.valueCents ? b.valueCents - a.valueCents : a.name.localeCompare(b.name))
    }
    // MARK: WealthIncome.make
    function makeIncome(txs, since) {
        const r = { dividends: 0, fees: 0, taxes: 0 }
        for (const t of txs) {
            if (t.currency !== "EUR" || t.booking_date < since) continue
            if (t.direction === "Dividend") r.dividends += t.value_cents
            else if (t.direction === "Fee") r.fees += Math.abs(t.value_cents)
            else if (t.direction === "Tax") r.taxes += Math.abs(t.value_cents)
            if (t.direction !== "Fee") r.fees += t.fees_cents
            if (t.direction !== "Tax") r.taxes += t.taxes_cents
        }
        return r
    }

    // MARK: Sachwerte rows
    /// One row per tangible item (not sold), with a subline that is never the item's own name.
    readonly property var tangibleRows: {
        const out = []
        for (const a of summary.tangibles)
            for (const item of AppModel.assetItems(a.id))
                if (!item.sold) out.push({ id: "i" + item.id, name: item.setup.name, subtitle: tangibleSubtitle(item), valueCents: item.holding.value_cents })
        return out.sort((a, b) => b.valueCents - a.valueCents)
    }
    /// WealthView.tangibleSubtitle: pieces (when not exactly one), „Edelmetall“, the note.
    function tangibleSubtitle(item) {
        const parts = []
        const q = item.holding.quantity
        if (q !== 1) parts.push(qsTr("%1 Stück").arg(qty(q)))
        if (item.setup.price_source !== "manual") parts.push(qsTr("Edelmetall"))
        if (item.setup.note) parts.push(item.setup.note)
        return parts.join(" · ")
    }

    // MARK: formatting
    function qty(q) { return Number(q).toLocaleString(Qt.locale(), "f", 4).replace(/[.,]?0+$/, "") }
    /// .percent.precision(.fractionLength(1))
    function percent(x) {
        const n = Number(x * 100).toLocaleString(Qt.locale(), "f", 1)
        return Fmt.english ? n + "%" : n + " %"
    }
    function tone(c) { return c > 0 ? Theme.inflow : c < 0 ? Theme.negative : Theme.secondary }

    // MARK: WealthPalette
    readonly property var hues: [Theme.c("#2F6FDB", "#6EA0F5"), Theme.c("#1F7A5C", "#5EC79F"), Theme.c("#D98A00", "#F5B94A"),
                                 Theme.c("#8E4FC4", "#B98AE6"), Theme.c("#D1495B", "#F27F8E"), Theme.c("#0E8FA8", "#5CC6DB"),
                                 Theme.c("#7A8B99", "#A3B1C4")]
    function hue(i) { return hues[i % hues.length] }
    /// Largest seven, the rest folded into „Sonstige“.
    function topSlices(rows) {
        const sorted = rows.filter(r => r.cents > 0).sort((a, b) => b.cents - a.cents)
        const out = sorted.slice(0, 7).map((r, i) => ({ id: r.id, label: r.label, cents: r.cents, color: hue(i) }))
        const rest = sorted.slice(7).reduce((t, r) => t + r.cents, 0)
        if (rest > 0) out.push({ id: "rest", label: qsTr("Sonstige"), cents: rest, color: hue(6) })
        return out
    }
    /// The donut: a bucket, an account or a position per slice.
    readonly property var composition: {
        const s = summary
        switch (scope) {
        case "cash":
            return { title: qsTr("Cash nach Konto"), slices: topSlices(s.cash.map(a => ({ id: String(a.id), label: a.name, cents: a.balance_cents }))) }
        case "securities": {
            // depots that only report a total (no positions): visible remainder
            const rest = s.securitiesCents - positions.reduce((t, p) => t + p.valueCents, 0)
            const parts = topSlices(positions.map(p => ({ id: p.id, label: p.name, cents: p.valueCents })))
            if (rest > 0) parts.push({ id: "uncovered", label: qsTr("Ohne Positionsdaten"), cents: rest, color: Theme.neutralTile })
            return { title: qsTr("Wertpapiere nach Position"), slices: parts }
        }
        case "tangibles":
            return { title: qsTr("Sachwerte nach Position"), slices: topSlices(tangibleRows.map(r => ({ id: r.id, label: r.name, cents: r.valueCents }))) }
        default: {
            // one fixed colour per bucket, so the legend colours never collide
            const out = [
                { id: "cash", label: qsTr("Cash"), cents: s.cashCents, color: hue(1) },
                { id: "securities", label: qsTr("Wertpapiere"), cents: s.securitiesCents, color: hue(0) },
                { id: "tangibles", label: qsTr("Sachwerte"), cents: s.tangiblesCents, color: hue(2) },
                { id: "credit", label: qsTr("Kartenguthaben"), cents: s.creditCents, color: hue(3) }
            ]
            return { title: qsTr("Zusammensetzung"), slices: out.filter(x => x.cents > 0) }
        }
        }
    }

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight + 40
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: AppScrollBar {}

        ColumnLayout {
            id: content
            x: 20; y: 20
            width: flick.width - 40
            spacing: 16

            Text { text: qsTr("Vermögen"); font.pixelSize: Theme.title2; font.weight: Font.DemiBold; color: Theme.text }

            // side by side when there is room, else stacked
            GridLayout {
                Layout.fillWidth: true
                columns: content.width >= 340 + 16 + 420 ? 2 : 1
                columnSpacing: 16; rowSpacing: 16
                SummaryCard {
                    Layout.fillWidth: parent.columns === 1
                    Layout.preferredWidth: parent.columns === 1 ? -1 : 340
                    Layout.alignment: Qt.AlignTop
                }
                CompositionCard { Layout.fillWidth: true; Layout.alignment: Qt.AlignTop }
            }
            CashHistoryCard { visible: wv.scope === "all" || wv.scope === "cash"; Layout.fillWidth: true }
            ListCard { shown: wv.scope === "all" || wv.scope === "cash"; Layout.fillWidth: true
                       title: qsTr("Cash"); total: wv.summary.cashCents; accounts: wv.summary.cash; tint: Theme.inflow }
            IncomeCard { visible: wv.scope === "securities" && !wv.incomeEmpty; Layout.fillWidth: true }
            ListCard { shown: wv.scope === "all" || wv.scope === "securities"; Layout.fillWidth: true
                       title: qsTr("Wertpapiere"); total: wv.summary.securitiesCents; accounts: wv.summary.securities; tint: Theme.invest }
            IncomeCard { visible: wv.scope === "all" && !wv.incomeEmpty; Layout.fillWidth: true }
            PositionsCard { visible: (wv.scope === "all" || wv.scope === "securities") && wv.positions.length > 0; Layout.fillWidth: true }
            ListCard { shown: wv.scope === "all"; Layout.fillWidth: true
                       title: qsTr("Sachwerte"); total: wv.summary.tangiblesCents; accounts: wv.summary.tangibles; tint: Theme.invest }
            TangiblesCard { visible: wv.scope === "tangibles" && wv.tangibleRows.length > 0; Layout.fillWidth: true }
            ListCard { shown: wv.scope === "all"; Layout.fillWidth: true
                       title: qsTr("Verbindlichkeiten"); total: wv.summary.liabilitiesTotal; accounts: wv.summary.liabilities; tint: Theme.negative }
            Text {
                visible: wv.scope === "all" && wv.summary.foreign > 0
                text: qsTr("%1 Konten in Fremdwährung sind nicht enthalten.").arg(wv.summary.foreign)
                font.pixelSize: Theme.caption; color: Theme.secondary
            }
        }
    }

    // MARK: summary (net worth + assets / liabilities bars)
    component SummaryCard: Card {
        id: sc
        padding: 18
        readonly property real assets: Math.max(wv.summary.grossCents, 0)
        readonly property real debts: -Math.min(wv.summary.liabilitiesCents, 0)
        readonly property real scale: Math.max(assets, debts, 1)
        implicitWidth: 340
        ColumnLayout {
            width: parent.width; spacing: 14
            Text { text: qsTr("Nettovermögen"); font.pixelSize: Theme.caption; color: Theme.secondary }
            Text {
                Layout.fillWidth: true
                text: Fmt.money(wv.netCents(wv.summary))
                font.pixelSize: 36; font.weight: Font.DemiBold; font.features: { "tnum": 1 }
                color: Theme.text
                fontSizeMode: Text.HorizontalFit; minimumPixelSize: 22; elide: Text.ElideNone
            }
            Bar { title: qsTr("Vermögenswerte"); cents: sc.assets; fraction: sc.assets / sc.scale; tint: Theme.accent }
            Bar { title: qsTr("Verbindlichkeiten"); cents: -sc.debts; fraction: sc.debts / sc.scale; tint: Theme.negative
                  opacity: prefs.includeLiabilities ? 1 : 0.45 }
            CheckBox {
                visible: sc.debts > 0
                text: qsTr("Kredite und Karten abziehen")
                font.pixelSize: Theme.callout + 1
                checked: prefs.includeLiabilities
                onToggled: prefs.includeLiabilities = checked
                leftPadding: 0
            }
        }
    }
    component Bar: ColumnLayout {
        id: bar
        property string title
        property real cents
        property real fraction
        property color tint
        Layout.fillWidth: true
        spacing: 4
        RowLayout {
            Layout.fillWidth: true
            Text { text: bar.title; font.pixelSize: Theme.subheadline + 1; font.weight: Font.Medium; color: Theme.text; Layout.fillWidth: true }
            Text { text: Fmt.money(bar.cents); font.pixelSize: Theme.subheadline + 1; font.features: { "tnum": 1 }; color: Theme.text }
        }
        Item {
            Layout.fillWidth: true; implicitHeight: 6
            Rectangle { anchors.fill: parent; radius: 3; color: Theme.neutralTile }
            Rectangle { height: parent.height; radius: 3; color: bar.tint
                        width: Math.max(parent.width * bar.fraction, bar.fraction > 0 ? 4 : 0) }
        }
    }

    // MARK: composition donut
    component CompositionCard: Card {
        id: cc
        padding: 18
        readonly property var parts: wv.composition.slices
        readonly property real total: parts.reduce((t, p) => t + p.cents, 0)
        /// ViewThatFits: donut and legend side by side, else stacked
        readonly property bool vertical: width - 36 < 190 + 36 + legend.implicitWidth
        ColumnLayout {
            width: parent.width; spacing: 12
            Text { text: wv.composition.title; font.pixelSize: Theme.caption; color: Theme.secondary }
            Text { visible: cc.parts.length === 0; text: qsTr("Keine Daten"); color: Theme.secondary; font.pixelSize: Theme.body
                   Layout.fillWidth: true; Layout.minimumHeight: 120; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
            GridLayout {
                visible: cc.parts.length > 0
                Layout.alignment: Qt.AlignHCenter
                columns: cc.vertical ? 1 : 2
                columnSpacing: 36; rowSpacing: 16
                Donut { parts: cc.parts; total: cc.total; Layout.alignment: Qt.AlignHCenter }
                ColumnLayout {
                    id: legend
                    Layout.alignment: Qt.AlignVCenter | (cc.vertical ? Qt.AlignHCenter : Qt.AlignLeft)
                    spacing: 12
                    Repeater {
                        model: cc.parts
                        RowLayout {
                            required property var modelData
                            spacing: 8
                            Rectangle { width: 9; height: 9; radius: 4.5; color: modelData.color }
                            ColumnLayout { spacing: 0
                                Text { text: modelData.label; font.pixelSize: Theme.callout + 1; color: Theme.text }
                                Text { text: Fmt.money(modelData.cents) + " (" + wv.percent(modelData.cents / Math.max(cc.total, 1)) + ")"
                                       font.pixelSize: Theme.caption; font.features: { "tnum": 1 }; color: Theme.secondary } }
                        }
                    }
                }
            }
        }
    }
    component Donut: Item {
        id: donut
        property var parts: []
        property real total: 0
        implicitWidth: 190; implicitHeight: 190
        onPartsChanged: canvas.requestPaint()
        Connections { target: Theme; function onDarkChanged() { canvas.requestPaint() } }
        Canvas {
            id: canvas
            anchors.fill: parent
            onPaint: {
                const ctx = getContext("2d")
                ctx.reset()
                const sum = donut.parts.reduce((t, p) => t + p.cents, 0)
                if (sum <= 0) return
                const cx = width / 2, cy = height / 2, r = Math.min(width, height) / 2, inner = r * 0.62
                // angularInset 1.5 pt on each side of a sector
                const inset = donut.parts.length > 1 ? 1.5 : 0
                let a = -Math.PI / 2
                for (const p of donut.parts) {
                    const span = p.cents / sum * 2 * Math.PI
                    const o = inset / r, i = inset / inner
                    if (span > 2 * o) {
                        ctx.beginPath()
                        ctx.arc(cx, cy, r, a + o, a + span - o, false)
                        ctx.arc(cx, cy, inner, a + span - Math.min(i, span / 2), a + Math.min(i, span / 2), true)
                        ctx.closePath()
                        ctx.fillStyle = p.color
                        ctx.fill()
                    }
                    a += span
                }
            }
        }
        ColumnLayout {
            anchors.centerIn: parent
            width: 100; spacing: 0
            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: Fmt.money(donut.total)
                   font.pixelSize: Theme.callout + 1; font.weight: Font.DemiBold; font.features: { "tnum": 1 }; color: Theme.text
                   fontSizeMode: Text.HorizontalFit; minimumPixelSize: 8 }
            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: qsTr("Summe"); font.pixelSize: Theme.caption2; color: Theme.secondary }
        }
    }

    // MARK: lists
    component CardTitle: RowLayout {
        property string title
        property var total: null
        Layout.fillWidth: true
        Text { text: parent.title; font.pixelSize: Theme.subheadline + 2; font.weight: Font.DemiBold; color: Theme.text; Layout.fillWidth: true }
        Text { visible: parent.total !== null; text: parent.total !== null ? Fmt.money(parent.total) : ""
               font.pixelSize: Theme.subheadline + 2; font.weight: Font.DemiBold; font.features: { "tnum": 1 }; color: Theme.text }
    }
    component Divider: Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }

    component ListCard: Card {
        id: lc
        property string title
        property real total
        property var accounts: []
        property color tint
        property bool shown: true
        padding: 18
        visible: shown && accounts.length > 0
        ColumnLayout {
            width: parent.width; spacing: 8
            CardTitle { title: lc.title; total: lc.total }
            Divider {}
            Repeater {
                model: lc.accounts.slice().sort((a, b) => Math.abs(b.balance_cents) - Math.abs(a.balance_cents))
                RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 8
                    SFIcon { symbol: modelData.sf_symbol; size: 15; color: lc.tint; Layout.preferredWidth: 20 }
                    ColumnLayout { spacing: 1; Layout.fillWidth: true
                        Text { text: modelData.name; font.pixelSize: Theme.body; color: Theme.text; elide: Text.ElideRight; Layout.fillWidth: true }
                        Text { visible: modelData.bank_name !== ""; text: modelData.bank_name; font.pixelSize: Theme.caption2; color: Theme.secondary
                               elide: Text.ElideRight; Layout.fillWidth: true } }
                    Text { text: Fmt.money(modelData.balance_cents); font.pixelSize: Theme.body; font.features: { "tnum": 1 }; color: Theme.text }
                    TapHandler { cursorShape: Qt.PointingHandCursor; onTapped: AppModel.sidebarSelection = "account:" + modelData.id }
                }
            }
        }
    }

    component PositionsCard: Card {
        id: pc
        padding: 18
        readonly property var shown: wv.positions
        readonly property var day: shown.filter(p => p.dayChangeCents !== null)
        readonly property var gain: shown.filter(p => p.gainCents !== null)
        readonly property var cov: ({ lines: shown.reduce((t, p) => t + p.lines, 0), day: shown.reduce((t, p) => t + p.dayLines, 0),
                                      gain: shown.reduce((t, p) => t + p.gainLines, 0) })
        readonly property real total: wv.summary.securitiesCents
        ColumnLayout {
            width: parent.width; spacing: 8
            CardTitle { title: qsTr("Positionen aller Depots") }
            RowLayout {
                visible: pc.day.length > 0 || pc.gain.length > 0
                spacing: 18
                Change { visible: pc.day.length > 0; title: qsTr("Heute"); cents: pc.day.reduce((t, p) => t + p.dayChangeCents, 0) }
                Change { visible: pc.gain.length > 0; title: qsTr("Gewinn/Verlust"); cents: pc.gain.reduce((t, p) => t + p.gainCents, 0) }
            }
            // sums of the reported values only, not the whole depot value
            Text {
                visible: (pc.day.length > 0 || pc.gain.length > 0) && (pc.cov.day < pc.cov.lines || pc.cov.gain < pc.cov.lines)
                Layout.fillWidth: true; wrapMode: Text.Wrap
                text: qsTr("Nur Bestände mit verfügbaren Daten: Heute %1 von %2, Gewinn/Verlust %3 von %4.")
                      .arg(pc.cov.day).arg(pc.cov.lines).arg(pc.cov.gain).arg(pc.cov.lines)
                font.pixelSize: Theme.caption; color: Theme.secondary
            }
            Divider {}
            Repeater {
                model: pc.shown
                RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    ColumnLayout { spacing: 1; Layout.fillWidth: true
                        Text { text: modelData.name; font.pixelSize: Theme.body; color: Theme.text; elide: Text.ElideRight; Layout.fillWidth: true }
                        Text { text: wv.qty(modelData.quantity) + " · " + modelData.id; font.pixelSize: Theme.caption2; color: Theme.secondary
                               elide: Text.ElideRight; Layout.fillWidth: true } }
                    ColumnLayout { spacing: 1
                        Text { Layout.alignment: Qt.AlignRight; text: Fmt.money(modelData.valueCents); font.pixelSize: Theme.body; font.features: { "tnum": 1 }; color: Theme.text }
                        Text { Layout.alignment: Qt.AlignRight; visible: modelData.dayChangeCents !== null
                               text: modelData.dayChangeCents !== null ? Fmt.signed(modelData.dayChangeCents) : ""
                               font.pixelSize: Theme.caption2; font.features: { "tnum": 1 }; color: wv.tone(modelData.dayChangeCents) }
                        Text { Layout.alignment: Qt.AlignRight; visible: pc.total > 0; text: wv.percent(modelData.valueCents / Math.max(pc.total, 1))
                               font.pixelSize: Theme.caption2; font.features: { "tnum": 1 }; color: Theme.secondary } }
                }
            }
        }
    }
    component Change: RowLayout {
        property string title
        property real cents
        spacing: 6
        Text { text: parent.title; font.pixelSize: Theme.caption; color: Theme.secondary }
        Text { text: Fmt.signed(parent.cents); font.pixelSize: Theme.callout + 1; font.weight: Font.Medium; font.features: { "tnum": 1 }; color: wv.tone(parent.cents) }
    }

    component TangiblesCard: Card {
        id: tc
        padding: 18
        readonly property real total: wv.summary.tangiblesCents
        ColumnLayout {
            width: parent.width; spacing: 8
            CardTitle { title: qsTr("Positionen der Sachwerte") }
            Divider {}
            Repeater {
                model: wv.tangibleRows
                RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    ColumnLayout { spacing: 1; Layout.fillWidth: true
                        Text { text: modelData.name; font.pixelSize: Theme.body; color: Theme.text; elide: Text.ElideRight; Layout.fillWidth: true }
                        Text { visible: modelData.subtitle !== ""; text: modelData.subtitle; font.pixelSize: Theme.caption2; color: Theme.secondary
                               elide: Text.ElideRight; Layout.fillWidth: true } }
                    ColumnLayout { spacing: 1
                        Text { Layout.alignment: Qt.AlignRight; text: Fmt.money(modelData.valueCents); font.pixelSize: Theme.body; font.features: { "tnum": 1 }; color: Theme.text }
                        Text { Layout.alignment: Qt.AlignRight; visible: tc.total > 0; text: wv.percent(modelData.valueCents / Math.max(tc.total, 1))
                               font.pixelSize: Theme.caption2; font.features: { "tnum": 1 }; color: Theme.secondary } }
                }
            }
        }
    }

    /// Distributions, fees and taxes of the depots over the last twelve months.
    component IncomeCard: Card {
        padding: 18
        ColumnLayout {
            width: parent.width; spacing: 8
            CardTitle { title: qsTr("Erträge und Kosten") }
            Text { text: qsTr("Letzte 12 Monate, aus den Wertpapierumsätzen der Depots."); font.pixelSize: Theme.caption; color: Theme.secondary
                   Layout.fillWidth: true; wrapMode: Text.Wrap }
            Divider {}
            IncomeRow { title: qsTr("Ausschüttungen"); cents: wv.income.dividends; tint: Theme.inflow }
            IncomeRow { title: qsTr("Gebühren"); cents: -wv.income.fees; tint: Theme.negative }
            IncomeRow { title: qsTr("Steuern"); cents: -wv.income.taxes; tint: Theme.negative }
        }
    }
    component IncomeRow: RowLayout {
        property string title
        property real cents
        property color tint
        visible: cents !== 0
        Layout.fillWidth: true
        Text { text: parent.title; font.pixelSize: Theme.body; color: Theme.text; Layout.fillWidth: true }
        Text { text: Fmt.money(parent.cents); font.pixelSize: Theme.body; font.features: { "tnum": 1 }; color: parent.tint }
    }

    // MARK: cash history (area chart, back-calculated from bookings)
    component CashHistoryCard: Card {
        id: hc
        padding: 18
        ColumnLayout {
            width: parent.width; spacing: 10
            RowLayout {
                Layout.fillWidth: true
                ColumnLayout { spacing: 1; Layout.fillWidth: true
                    Text { text: qsTr("Cash-Verlauf"); font.pixelSize: Theme.subheadline + 2; font.weight: Font.DemiBold; color: Theme.text }
                    Text { text: qsTr("Aus den Buchungen zurückgerechnet; Depots sind nicht enthalten."); font.pixelSize: Theme.caption; color: Theme.secondary
                           Layout.fillWidth: true; wrapMode: Text.Wrap } }
                Segmented {
                    options: [{ id: "90", title: qsTr("3 Monate") }, { id: "365", title: qsTr("1 Jahr") },
                              { id: "1095", title: qsTr("3 Jahre") }, { id: "1825", title: qsTr("5 Jahre") }]
                    current: String(wv.historyDays)
                    onActivated: id => wv.historyDays = Number(id)
                }
            }
            Text { visible: wv.history.length < 2; text: qsTr("Keine Daten"); color: Theme.secondary; font.pixelSize: Theme.body
                   Layout.fillWidth: true; Layout.minimumHeight: 120; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
            CashChart { visible: wv.history.length >= 2; points: wv.history; Layout.fillWidth: true; Layout.preferredHeight: 190 }
        }
    }
    /// Area + line with a value axis on the trailing side (Swift Charts' AxisMarks(position: .trailing)).
    component CashChart: Item {
        id: cash
        property var points: []
        FontMetrics { id: axisFont; font.pixelSize: Theme.caption2 }
        readonly property var stats: {
            let lo = Infinity, hi = -Infinity
            for (const p of points) { lo = Math.min(lo, p.balance_cents); hi = Math.max(hi, p.balance_cents) }
            const pad = Math.max((hi - lo) * 0.1, 100)
            return { lo: lo - pad, hi: hi + pad }
        }
        /// About five round values inside the domain.
        readonly property var ticks: {
            const span = stats.hi - stats.lo
            if (!(span > 0)) return []
            const raw = span / 4, mag = Math.pow(10, Math.floor(Math.log10(raw)))
            const step = [1, 2, 2.5, 5, 10].map(f => f * mag).find(s => s >= raw) || raw
            const out = []
            for (let v = Math.ceil(stats.lo / step) * step; v <= stats.hi; v += step) out.push(v)
            return out
        }
        readonly property real axisWidth: ticks.reduce((w, t) => Math.max(w, axisFont.advanceWidth(Fmt.money(Math.round(t)))), 0) + 8
        readonly property real plotWidth: width - axisWidth
        function xAt(i) { return points.length < 2 ? 0 : i / (points.length - 1) * plotWidth }
        function yAt(c) { return height - (c - stats.lo) / (stats.hi - stats.lo) * height }
        onPointsChanged: canvas.requestPaint()
        onWidthChanged: canvas.requestPaint()
        Connections { target: Theme; function onDarkChanged() { canvas.requestPaint() } }
        Canvas {
            id: canvas
            anchors.fill: parent
            onPaint: {
                const ctx = getContext("2d")
                ctx.reset()
                const pts = cash.points
                if (pts.length < 2) return
                ctx.strokeStyle = Theme.withAlpha(Theme.tertiary, 0.25); ctx.lineWidth = 1
                for (const t of cash.ticks) {
                    const y = Math.round(cash.yAt(t)) + 0.5
                    ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(cash.plotWidth, y); ctx.stroke()
                }
                const step = Math.max(1, Math.floor(pts.length / Math.max(2, cash.plotWidth / 2)))
                ctx.beginPath()
                ctx.moveTo(0, cash.yAt(pts[0].balance_cents))
                for (let i = step; i < pts.length; i += step) ctx.lineTo(cash.xAt(i), cash.yAt(pts[i].balance_cents))
                ctx.lineTo(cash.plotWidth, cash.yAt(pts[pts.length - 1].balance_cents))
                ctx.lineTo(cash.plotWidth, cash.height); ctx.lineTo(0, cash.height); ctx.closePath()
                const g = ctx.createLinearGradient(0, 0, 0, cash.height)
                g.addColorStop(0, Theme.withAlpha(Theme.accent, 0.35)); g.addColorStop(1, Theme.withAlpha(Theme.accent, 0.03))
                ctx.fillStyle = g; ctx.fill()
                ctx.beginPath()
                ctx.moveTo(0, cash.yAt(pts[0].balance_cents))
                for (let i = step; i < pts.length; i += step) ctx.lineTo(cash.xAt(i), cash.yAt(pts[i].balance_cents))
                ctx.lineTo(cash.plotWidth, cash.yAt(pts[pts.length - 1].balance_cents))
                ctx.strokeStyle = Theme.accent; ctx.lineWidth = 2; ctx.stroke()
            }
        }
        Repeater {
            model: cash.ticks
            Text {
                required property var modelData
                x: cash.plotWidth + 6
                y: Math.max(0, Math.min(cash.height - height, cash.yAt(modelData) - height / 2))
                text: Fmt.money(Math.round(modelData)); font.pixelSize: Theme.caption2; color: Theme.secondary
            }
        }
    }
}
