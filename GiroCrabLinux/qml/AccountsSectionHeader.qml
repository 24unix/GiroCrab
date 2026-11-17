import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// AccountGroupsUI.swift › AccountsSectionHeader: chevron + "Konten" (folds the account tree,
// SidebarModel.accountsCollapsed) + archive toggle, group actions,
// Gruppen/Banken/Kontoart picker, account search. The ListView header (not a row): the
// search field keeps its focus while the rows below are rebuilt on every keystroke.
Item {
    id: header
    width: parent ? parent.width : 200
    implicitHeight: AppModel.allAccounts.length ? col.implicitHeight + 22 : 0
    height: implicitHeight
    visible: AppModel.allAccounts.length > 0
    ColumnLayout {
        id: col
        anchors.left: parent.left; anchors.right: parent.right
        anchors.leftMargin: 8 + SidebarModel.rowLeading; anchors.rightMargin: 14; anchors.top: parent.top; anchors.topMargin: 12
        spacing: 6
        RowLayout {
            spacing: 2
            // same height in every view (#596): the buttons only exist under „Gruppen“
            Layout.minimumHeight: 20
            SidebarChevron {
                open: !SidebarModel.accountsCollapsed
                Layout.rightMargin: SidebarModel.gap - 2
                accessibleName: open ? qsTr("Konten einklappen") : qsTr("Konten ausklappen")
                onToggled: SidebarModel.accountsCollapsed = !SidebarModel.accountsCollapsed
            }
            Text { text: qsTr("Konten"); font.pixelSize: Theme.caption; font.weight: Font.DemiBold; color: Theme.secondary
                   Accessible.role: Accessible.Heading
                   TapHandler { onTapped: SidebarModel.accountsCollapsed = !SidebarModel.accountsCollapsed } }
            Item { Layout.fillWidth: true }
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
            options: [{ id: "byGroup", title: qsTr("Gruppen") }, { id: "byBank", title: qsTr("Banken") }, { id: "byKind", title: qsTr("Kontoart") }]
            current: AppModel.accountView
            onActivated: id => AppModel.setAccountView(id)
        }
        Rectangle {
            Layout.fillWidth: true
            Layout.topMargin: 6
            implicitHeight: searchRow.implicitHeight + 10
            radius: 6
            color: Theme.withAlpha(Theme.tertiary, 0.12)
            Accessible.name: qsTr("Konten suchen")
            RowLayout {
                id: searchRow
                anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                spacing: 6
                SFIcon { symbol: "magnifyingglass"; size: Theme.caption; color: Theme.tertiary }
                TextField {
                    id: search
                    Layout.fillWidth: true
                    padding: 0; leftPadding: 0; rightPadding: 0
                    background: null
                    placeholderText: qsTr("Suchen…")
                    font.pixelSize: Theme.caption
                    color: Theme.text
                    text: AppModel.sidebarAccountSearch
                    onTextEdited: AppModel.sidebarAccountSearch = text
                    Keys.onEscapePressed: AppModel.sidebarAccountSearch = ""
                    Sensitive { when: search.text !== "" }   // typed owner names / IBANs (#301)
                }
                IconButton {
                    visible: AppModel.sidebarAccountSearch !== ""
                    symbol: "xmark.circle.fill"; symbolSize: Theme.caption; tint: Theme.tertiary
                    implicitWidth: 16; implicitHeight: 16
                    Accessible.name: qsTr("Suche löschen")
                    onClicked: AppModel.sidebarAccountSearch = ""
                }
            }
        }
    }
}
