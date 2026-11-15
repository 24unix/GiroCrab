import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// PlanningUI.swift › SplitSheet: split one booking (`AppModel.splitBooking`)
// into category parts that add up to its amount.
Sheet {
    id: sheet
    readonly property var booking: AppModel.splitBooking
    /// [{ uid, categoryID, amount, note }] – edits bump `revision` instead of
    /// rebuilding the list, so the field being typed in keeps its focus.
    property var parts: []
    property int revision: 0
    property int nextUid: 0
    property string error: ""
    /// The booking is split already (loaded with the parts).
    property bool hasSplits: false
    visible: booking !== null
    sheetWidth: 560
    padding: 22
    onClosed: { AppModel.splitBooking = null; parts = [] }

    readonly property real total: booking ? Math.abs(booking.amount_cents) : 0
    readonly property int sign: booking && booking.amount_cents < 0 ? -1 : 1
    function cents(p) { const c = AppModel.parseCents(p.amount); return c === null ? 0 : c }
    readonly property real remaining: { revision; return total - parts.reduce((s, p) => s + cents(p), 0) }
    readonly property bool valid: { revision; return parts.length >= 2 && remaining === 0 && parts.every(p => cents(p) > 0) }
    function part(categoryID, amount, note) { return { uid: nextUid++, categoryID: categoryID, amount: amount, note: note } }

    onAboutToShow: {
        error = ""; hasSplits = false; parts = []
        const b = booking
        AppModel.splits(b, existing => {
            if (sheet.booking !== b) return
            if (existing === null) {
                // never offer a fresh split over one that could not be read
                error = qsTr("Die bestehende Aufteilung konnte nicht geladen werden.")
                return
            }
            hasSplits = existing.length > 0
            parts = existing.length === 0
                ? [part(b.category_id, Fmt.plain(total), ""), part(null, "", "")]
                : existing.map(s => part(s.category_id, Fmt.plain(Math.abs(s.amount_cents)), s.note))
        })
    }
    function save() {
        if (!valid) return
        const inputs = parts.map(p => ({ category_id: p.categoryID, amount_cents: sign * cents(p), note: p.note }))
        error = AppModel.saveSplits(inputs, booking)
        if (error === "") close()
    }

    readonly property var categoryOptions: [{ id: null, title: qsTr("Ohne Kategorie") }]
        .concat(AppModel.categories.map(c => ({ id: c.id, title: c.path })))

    ColumnLayout {
        width: sheet.availableWidth
        spacing: 14
        Text { text: qsTr("Umsatz aufteilen"); font.pixelSize: Theme.title3 + 1; font.weight: Font.Bold; color: Theme.text }
        Text {
            text: sheet.booking ? sheet.booking.merchant_name + " · " + Fmt.money(sheet.booking.amount_cents) : ""
            font.pixelSize: Theme.body; color: Theme.secondary
        }
        Repeater {
            model: sheet.parts
            RowLayout {
                id: row
                required property var modelData
                required property int index
                Layout.fillWidth: true
                spacing: 8
                AppComboBox {
                    Layout.preferredWidth: 190
                    model: sheet.categoryOptions
                    textRole: "title"
                    currentIndex: Math.max(0, sheet.categoryOptions.findIndex(o => o.id === row.modelData.categoryID))
                    onActivated: i => { sheet.parts[row.index].categoryID = sheet.categoryOptions[i].id; sheet.revision++ }
                }
                TextField {
                    Layout.preferredWidth: 90
                    text: row.modelData.amount
                    placeholderText: Fmt.plain(0)
                    horizontalAlignment: TextInput.AlignRight
                    font.features: { "tnum": 1 }
                    onTextEdited: { sheet.parts[row.index].amount = text; sheet.revision++ }
                }
                TextField {
                    Layout.fillWidth: true
                    text: row.modelData.note
                    placeholderText: qsTr("Notiz")
                    onTextEdited: sheet.parts[row.index].note = text
                }
                IconButton {
                    visible: sheet.parts.length > 2
                    symbol: "minus.circle"
                    ToolTip.text: qsTr("Aufteilung entfernen")
                    Accessible.name: qsTr("Aufteilung entfernen")
                    onClicked: sheet.parts = sheet.parts.filter(p => p.uid !== row.modelData.uid)
                }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            IconButton {
                text: qsTr("Teil hinzufügen"); symbol: "plus"; symbolSize: 13
                onClicked: sheet.parts = sheet.parts.concat([sheet.part(null, sheet.remaining > 0 ? Fmt.plain(sheet.remaining) : "", "")])
            }
            Item { Layout.fillWidth: true }
            Text {
                text: qsTr("Rest: %1").arg(Fmt.money(sheet.remaining))
                font.pixelSize: Theme.callout + 1; font.features: { "tnum": 1 }
                color: sheet.remaining === 0 ? Theme.inflow : Theme.warning
            }
        }
        Text { visible: sheet.error !== ""; text: sheet.error; font.pixelSize: Theme.callout + 1; color: Theme.negative; wrapMode: Text.WordWrap; Layout.fillWidth: true }
        RowLayout {
            Layout.fillWidth: true
            Button {
                visible: sheet.hasSplits
                text: qsTr("Aufteilung aufheben")
                palette.buttonText: Theme.negative
                onClicked: { sheet.error = AppModel.saveSplits([], sheet.booking); if (sheet.error === "") sheet.close() }
            }
            Item { Layout.fillWidth: true }
            Button { text: qsTr("Abbrechen"); onClicked: sheet.close() }
            Button { text: qsTr("Speichern"); highlighted: true; enabled: sheet.valid; onClicked: sheet.save() }
        }
    }
}
