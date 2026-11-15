import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

// DocumentsUI.swift › DocumentsView: "Belege & PostBox" – list left, preview right.
Rectangle {
    id: view
    color: Theme.canvas
    property string search: ""
    property bool unlinkedOnly: false
    /// List selection by id; the shown document is looked up in `docs`, so one that is
    /// filtered out or deleted leaves the preview (Swift: `docs.first { $0.id == selected }`).
    property var selectedID: null
    readonly property var selected: selectedID === null ? null : (docs.find(d => d.id === selectedID) || null)
    property var docToDelete: null
    readonly property var docs: AppModel.sidebarSelection !== "documents" ? [] : AppModel.allDocuments(search, unlinkedOnly, AppModel.documentsAccountFilter)
    readonly property var filterAccount: AppModel.documentsAccountFilter === null ? null : AppModel.accountsByID[AppModel.documentsAccountFilter]

    // One context menu for all documents (built once, not per row).
    property var menuDoc: null
    AppMenu { id: docMenu
        AppMenuItem { text: qsTr("QuickLook"); onTriggered: AppModel.quickLook(view.menuDoc) }
        AppMenuItem { text: qsTr("Verknüpfung lösen"); onTriggered: AppModel.linkDocument(view.menuDoc, null) }
        AppMenuSeparator {}
        AppMenuItem { text: qsTr("Beleg löschen …"); onTriggered: view.docToDelete = view.menuDoc } }

    RowLayout {
        anchors.fill: parent
        spacing: 0
        ColumnLayout {
            // The list keeps its width; the preview takes what is left.
            Layout.preferredWidth: Math.min(520, Math.max(400, view.width * 0.55)); Layout.minimumWidth: 430; Layout.fillHeight: true
            clip: true
            Layout.margins: 18
            spacing: 12
            ColumnLayout { spacing: 4; Layout.fillWidth: true
                Text { text: qsTr("Belege & PostBox"); font.pixelSize: Theme.title2 + 3; font.weight: Font.DemiBold; color: Theme.text }
                Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption; color: Theme.secondary
                       text: qsTr("Wertpapierabrechnungen, Kontoauszüge, Kassenbons – verschlüsselt im Tresor. PDF oder Foto hierher ziehen: GiroCrab ordnet es dem passenden Umsatz zu.") } }
            RowLayout {
                spacing: 12; Layout.fillWidth: true
                AppComboBox {
                    Layout.minimumWidth: 120; Layout.maximumWidth: 240; Layout.fillWidth: true
                    model: [qsTr("Alle Konten")].concat(AppModel.allAccounts.map(a => a.name))
                    currentIndex: AppModel.documentsAccountFilter === null ? 0 : AppModel.allAccounts.findIndex(a => a.id === AppModel.documentsAccountFilter) + 1
                    onActivated: i => AppModel.documentsAccountFilter = i === 0 ? null : AppModel.allAccounts[i - 1].id
                    ToolTip.text: qsTr("Belege eines Kontos anzeigen"); ToolTip.visible: hovered
                }
                Switch { text: qsTr("Nur ohne Buchung"); checked: view.unlinkedOnly; onToggled: view.unlinkedOnly = checked }
                Item { Layout.fillWidth: true }
                Button { text: qsTr("Alle exportieren …"); icon.name: SF.icon("square.and.arrow.up"); onClicked: folderDialog.open()
                         display: view.width < 900 ? AbstractButton.IconOnly : AbstractButton.TextBesideIcon
                         ToolTip.text: text; ToolTip.visible: hovered && display === AbstractButton.IconOnly }
            }
            TextField { Layout.fillWidth: true; placeholderText: qsTr("Belege durchsuchen"); onTextChanged: view.search = text }
            ListView {
                id: list
                Layout.fillWidth: true; Layout.fillHeight: true
                clip: true
                model: view.docs
                ScrollBar.vertical: AppScrollBar {}
                delegate: Rectangle {
                    required property var modelData
                    width: ListView.view.width; height: 52
                    radius: 6
                    color: view.selectedID === modelData.id ? Theme.selection : "transparent"
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; spacing: 10
                        SFIcon { symbol: AppModel.docSymbol(modelData); size: 18; color: Theme.accent; Layout.preferredWidth: 22 }
                        ColumnLayout { spacing: 2; Layout.fillWidth: true
                            Text { text: modelData.title; font.pixelSize: Theme.body + 1; font.weight: Font.Medium; color: Theme.text; elide: Text.ElideRight; Layout.fillWidth: true }
                            Text { text: modelData.booking_label || qsTr("PostBox · %1").arg(modelData.account_name); font.pixelSize: Theme.caption
                                   color: modelData.booking_label ? Theme.secondary : Theme.warning; elide: Text.ElideRight; Layout.fillWidth: true } }
                        Text { text: Fmt.medium(modelData.doc_date); font.pixelSize: Theme.caption; font.features: { "tnum": 1 }; color: Theme.secondary }
                    }
                    MouseArea {
                        anchors.fill: parent; acceptedButtons: Qt.LeftButton | Qt.RightButton
                        onClicked: m => { view.selectedID = modelData.id
                                          if (m.button === Qt.RightButton) { view.menuDoc = modelData; docMenu.popup() } }
                        onDoubleClicked: AppModel.quickLook(modelData)
                    }
                }
                ColumnLayout {
                    anchors.centerIn: parent; visible: view.docs.length === 0; spacing: 8; width: parent.width - 40
                    SFIcon { Layout.alignment: Qt.AlignHCenter; symbol: "doc.on.doc"; size: 30 }
                    Text { Layout.alignment: Qt.AlignHCenter; font.pixelSize: Theme.title3 + 1; font.weight: Font.Bold; color: Theme.text
                           text: view.filterAccount ? qsTr("Keine Belege für „%1“").arg(view.filterAccount.name) : qsTr("Keine Belege") }
                    Text { visible: !view.filterAccount; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; color: Theme.secondary
                           text: qsTr("Belege kommen beim Abruf (Trade Republic, comdirect-PostBox, FinTS-Kontoauszug) oder per Drag & Drop.") }
                    Button { visible: view.filterAccount !== null; Layout.alignment: Qt.AlignHCenter; text: qsTr("Alle Konten anzeigen"); onClicked: AppModel.documentsAccountFilter = null }
                }
            }
        }
        Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: Theme.border }
        Item {
            Layout.fillWidth: true; Layout.fillHeight: true; Layout.preferredWidth: 520
            DocumentPreview { anchors.fill: parent; visible: view.selected !== null; doc: view.selected }
            ColumnLayout {
                anchors.centerIn: parent; visible: view.selected === null; spacing: 8
                SFIcon { Layout.alignment: Qt.AlignHCenter; symbol: "doc.richtext"; size: 30 }
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("Beleg auswählen"); font.pixelSize: Theme.title3 + 1; font.weight: Font.Bold; color: Theme.text }
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("Vorschau mit QtPdf"); color: Theme.secondary }
            }
        }
    }
    // .dropDestination: drop anywhere → auto-match
    DropArea {
        id: drop
        anchors.fill: parent
        onDropped: d => { if (d.hasUrls) AppModel.dropAnywhere(d.urls) }
    }
    Rectangle { anchors.fill: parent; anchors.margins: 8; visible: drop.containsDrag; color: "transparent"; radius: 14; border.color: Theme.accent; border.width: 2 }

    FolderDialog { id: folderDialog; title: qsTr("Ordner für die exportierten Belege wählen"); acceptLabel: qsTr("Exportieren")
                   onAccepted: AppModel.exportAllDocuments(AppModel.localPath(selectedFolder)) }
    Sheet {
        visible: view.docToDelete !== null
        onClosed: view.docToDelete = null
        sheetWidth: 380
        ColumnLayout { width: parent.width; spacing: 12
            Text { text: qsTr("Beleg löschen?"); font.pixelSize: Theme.body + 2; font.weight: Font.Bold; color: Theme.text }
            Text { text: view.docToDelete ? qsTr("„%1“ wird unwiderruflich gelöscht.").arg(view.docToDelete.title) : ""; wrapMode: Text.WordWrap; Layout.fillWidth: true; color: Theme.text }
            RowLayout { Item { Layout.fillWidth: true }
                Button { text: qsTr("Abbrechen"); onClicked: view.docToDelete = null }
                Button { text: qsTr("Löschen"); onClicked: { AppModel.deleteDocument(view.docToDelete); view.docToDelete = null } } } }
    }
}
