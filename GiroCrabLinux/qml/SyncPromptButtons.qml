import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// TwoFactorSheet.swift › SyncPromptButtons: Abbrechen / Alle abbrechen + Überspringen + default.
RowLayout {
    id: buttons
    property string defaultTitle: qsTr("Weiter")
    property bool defaultVisible: true
    property bool defaultEnabled: true
    signal cancel()
    signal accept()
    Button {
        text: AppModel.canSkipInSyncBatch ? qsTr("Alle abbrechen") : qsTr("Abbrechen")
        onClicked: AppModel.canSkipInSyncBatch ? AppModel.cancelAllSync() : buttons.cancel()
    }
    Item { Layout.fillWidth: true }
    Button { visible: AppModel.canSkipInSyncBatch; text: qsTr("Überspringen"); onClicked: buttons.cancel() }
    Button { visible: buttons.defaultVisible; text: AppModel.menuText(buttons.defaultTitle);   /* literal "&" */ highlighted: true; enabled: buttons.defaultEnabled; onClicked: buttons.accept() }
}
