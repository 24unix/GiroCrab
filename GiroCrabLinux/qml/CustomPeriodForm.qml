import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// PlanningUI.swift › CustomPeriodForm (GitHub #53): start and end date of the user-defined
// period. macOS shows it as a popover below the period menu; here it is a small sheet.
// HIG: prevent invalid input instead of correcting it afterwards – "Von" never after "Bis".
Sheet {
    id: sheet
    sheetWidth: 480
    visible: AppModel.showCustomPeriod
    onClosed: AppModel.showCustomPeriod = false
    property date from: new Date()
    property date to: new Date()
    onAboutToShow: {
        const a = Fmt.date(AppModel.customPeriodFrom) || new Date()
        const b = Fmt.date(AppModel.customPeriodTo) || new Date()
        from = a <= b ? a : b
        to = a <= b ? b : a
    }
    function apply() {
        AppModel.applyCustomPeriod(Fmt.iso(from), Fmt.iso(to))
        close()
    }
    ColumnLayout {
        width: sheet.availableWidth
        spacing: 12
        Text { text: qsTr("Eigener Zeitraum"); font.pixelSize: Theme.body + 2; font.weight: Font.DemiBold; color: Theme.text }
        GridLayout {
            columns: 2
            columnSpacing: 12; rowSpacing: 8
            Text { text: qsTr("Von"); font.pixelSize: Theme.body; color: Theme.text }
            DateField { date: sheet.from; maximum: sheet.to; onPicked: d => sheet.from = d }
            Text { text: qsTr("Bis"); font.pixelSize: Theme.body; color: Theme.text }
            DateField { date: sheet.to; minimum: sheet.from; onPicked: d => sheet.to = d }
        }
        RowLayout {
            Layout.fillWidth: true
            Item { Layout.fillWidth: true }
            Button { text: qsTr("Abbrechen"); onClicked: sheet.close() }
            Button { text: qsTr("Übernehmen"); highlighted: true; onClicked: sheet.apply() }
        }
    }
}
