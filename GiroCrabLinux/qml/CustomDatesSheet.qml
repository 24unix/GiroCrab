import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// RecurringUI.swift › CustomDatesSheet: custom recurrence, e.g. "15.03., 15.08." (every year
// on these days). Opened by "Individuell …" (inspector card) for AppModel.customRecurringBooking.
Sheet {
    id: sheet
    sheetWidth: 400
    readonly property var booking: AppModel.customRecurringBooking
    visible: booking !== null
    onClosed: AppModel.customRecurringBooking = null
    readonly property var parsed: AppModel.parseCustomDates(field.text)
    readonly property bool canSave: parsed.valid.length > 0 && parsed.invalid.length === 0
    onAboutToShow: {
        const s = AppModel.recurringSeries(booking)
        field.text = s && s.interval === "Custom" ? s.custom_dates.map(AppModel.customDateShort).join(", ") : ""
        field.forceActiveFocus()
    }
    function save() {
        if (!canSave) return
        AppModel.markRecurring(booking, "Custom", parsed.valid)
        close()
    }
    ColumnLayout {
        width: sheet.availableWidth
        spacing: 12
        Text { text: qsTr("Individueller Turnus"); font.pixelSize: Theme.body + 2; font.weight: Font.DemiBold; color: Theme.text }
        Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.callout + 1; color: Theme.secondary
               text: qsTr("Tage im Jahr, an denen die Buchung fällig ist, z. B. „15.03., 15.08.“.") }
        TextField { id: field; Layout.fillWidth: true; placeholderText: "15.03., 15.08."; onAccepted: sheet.save() }
        RowLayout {
            spacing: 5
            Layout.fillWidth: true
            SFIcon { visible: field.text.trim() !== ""; symbol: sheet.parsed.invalid.length ? "exclamationmark.triangle" : "calendar"; size: 11
                     color: sheet.parsed.invalid.length ? Theme.outflow : Theme.secondary }
            Text {
                Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption
                color: sheet.parsed.invalid.length ? Theme.outflow : Theme.secondary
                text: {
                    const p = sheet.parsed
                    if (p.invalid.length) return qsTr("Kein gültiges Datum: %1").arg(p.invalid.join(", "))
                    if (!p.valid.length) return " "
                    const days = p.valid.map(AppModel.customDateDisplay)
                    const joined = days.length > 1 ? days.slice(0, -1).join(", ") + qsTr(" und ") + days[days.length - 1] : days[0]
                    return qsTr("Jedes Jahr am %1").arg(joined)
                }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            Item { Layout.fillWidth: true }
            Button { text: qsTr("Abbrechen"); onClicked: sheet.close() }
            Button { text: qsTr("Speichern"); highlighted: true; enabled: sheet.canSave; onClicked: sheet.save() }
        }
    }
}
