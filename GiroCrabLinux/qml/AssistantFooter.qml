import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// MoneyMoneyImportSheet.swift › AssistantFooter: Abbrechen on the left, then
// Zurück (Alt+Left) and the default button (Return). Esc cancels via the sheet.
RowLayout {
    id: f
    property bool cancelDisabled: false
    property bool showBack: false
    property bool backDisabled: false
    property string nextTitle: qsTr("Fortfahren")
    property bool nextDisabled: false
    property bool busy: false
    /// Extra buttons between Zurück and the default button.
    default property alias extra: extraRow.data
    signal cancel()
    signal back()
    signal next()
    Layout.fillWidth: true
    spacing: 8
    Button { text: qsTr("Abbrechen"); enabled: !f.cancelDisabled; onClicked: f.cancel() }
    Item { Layout.fillWidth: true }
    BusyIndicator { visible: f.busy; running: f.busy; implicitWidth: 22; implicitHeight: 22 }
    Button {
        visible: f.showBack; text: qsTr("Zurück"); enabled: !f.backDisabled; onClicked: f.back()
        Shortcut { sequence: "Alt+Left"; enabled: f.showBack && !f.backDisabled && f.visible; onActivated: f.back() }
    }
    RowLayout { id: extraRow; spacing: 8; Layout.fillWidth: false }
    Button {
        text: AppModel.menuText(f.nextTitle); highlighted: true; enabled: !f.nextDisabled; onClicked: f.next()
        Shortcut { sequences: ["Return", "Enter"]; enabled: !f.nextDisabled && f.visible; onActivated: f.next() }
    }
}
