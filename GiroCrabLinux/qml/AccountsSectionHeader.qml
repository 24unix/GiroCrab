import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// AccountGroupsUI.swift › AccountsSectionHeader: "Konten" + archive toggle, group actions, Gruppen/Kontoart picker.
Item {
    width: ListView.view.width
    implicitHeight: col.implicitHeight + 14
    ColumnLayout {
        id: col
        anchors.left: parent.left; anchors.right: parent.right
        anchors.leftMargin: 18; anchors.rightMargin: 14; anchors.top: parent.top; anchors.topMargin: 14
        spacing: 6
        RowLayout {
            spacing: 2
            Text { text: qsTr("Konten"); font.pixelSize: Theme.caption; font.weight: Font.DemiBold; color: Theme.secondary; Layout.fillWidth: true }
            IconButton {
                readonly property string label: AppModel.showArchivedAccounts ? qsTr("Archivierte Konten ausblenden") : qsTr("Archivierte Konten einblenden")
                visible: AppModel.hasArchivedAccounts
                symbol: AppModel.showArchivedAccounts ? "archivebox.fill" : "archivebox"; symbolSize: 14
                implicitWidth: 26; implicitHeight: 20
                ToolTip.text: label; Accessible.name: label
                onClicked: AppModel.showArchivedAccounts = !AppModel.showArchivedAccounts
            }
            // folder symbols: these act on groups, not on accounts
            IconButton { visible: AppModel.accountView === "byGroup"; symbol: "folder.badge.plus"; symbolSize: 14
                         implicitWidth: 26; implicitHeight: 20; ToolTip.text: qsTr("Neue Gruppe …"); Accessible.name: qsTr("Neue Gruppe")
                         onClicked: AppModel.groupDialog = { kind: "create", movingAccount: null, parent: null } }
            IconButton { visible: AppModel.accountView === "byGroup"; symbol: "gearshape"; symbolSize: 14
                         implicitWidth: 26; implicitHeight: 20; ToolTip.text: qsTr("Gruppen bearbeiten …"); Accessible.name: qsTr("Gruppen bearbeiten")
                         onClicked: AppModel.openGroupManager() }
        }
        Segmented {
            Layout.fillWidth: true
            Accessible.name: qsTr("Konten anzeigen nach")
            options: [{ id: "byGroup", title: qsTr("Gruppen") }, { id: "byKind", title: qsTr("Kontoart") }]
            current: AppModel.accountView
            onActivated: id => AppModel.setAccountView(id)
        }
    }
}
