import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtCore

// AccountDocumentsUI.swift › AccountDocumentsSheet (+ AutoStatementsToggle, DocumentPreviewSheet).
Sheet {
    id: sheet
    readonly property var account: AppModel.accountDocumentsFor
    property var preview: null
    visible: account !== null
    onClosed: { AppModel.accountDocumentsFor = null; preview = null }
    sheetWidth: preview ? 760 : 560
    readonly property var docs: account ? AppModel.accountDocuments(account.id) : []
    readonly property bool canFetch: AppModel.canFetchStatements(account)
    // DocumentPreviewSheet's "Schließen" (.cancelAction): Esc closes the preview, not the sheet
    closePolicy: preview ? Popup.NoAutoClose : Popup.CloseOnEscape
    Shortcut { sequences: ["Esc"]; enabled: sheet.visible && sheet.preview !== null && !saveDialog.visible; onActivated: sheet.preview = null }
    // "Fertig" is the default button of the list (.keyboardShortcut(.defaultAction))
    Shortcut { sequences: ["Return", "Enter"]; enabled: sheet.visible && sheet.preview === null; onActivated: sheet.close() }

    // .fileExporter(… defaultFilename: doc.fileName without ".pdf")
    FileDialog {
        id: saveDialog
        title: qsTr("Sichern …")
        fileMode: FileDialog.SaveFile
        readonly property bool isPdf: sheet.preview !== null && sheet.preview.mime_type === "application/pdf"
        defaultSuffix: isPdf ? "pdf" : ""
        nameFilters: isPdf ? [qsTr("PDF-Dokumente (*.pdf)")] : [qsTr("Alle Dateien (*)")]
        currentFolder: StandardPaths.writableLocation(StandardPaths.DocumentsLocation)
        onAccepted: AppModel.exportDocument(sheet.preview, AppModel.localPath(selectedFile))
    }
    function saveDocument() {
        const name = (preview.file_name || preview.title).replace(".pdf", "")
        saveDialog.selectedFile = saveDialog.currentFolder + "/" + name + (saveDialog.isPdf ? ".pdf" : "")
        saveDialog.open()
    }
    ColumnLayout {
        width: sheet.availableWidth
        spacing: 12
        RowLayout {
            ColumnLayout { spacing: 2; Layout.fillWidth: true
                Text { text: sheet.preview ? sheet.preview.title : qsTr("Dokumente / Kontoauszüge"); font.pixelSize: Theme.title3 + 2; font.weight: Font.DemiBold; color: Theme.text; elide: Text.ElideRight; Layout.fillWidth: true }
                Text { text: sheet.account ? sheet.account.name : ""; font.pixelSize: Theme.caption; color: Theme.secondary } }
            Button { visible: sheet.preview !== null; text: qsTr("Sichern …"); icon.name: SF.icon("square.and.arrow.down"); onClicked: sheet.saveDocument() }
            Button { visible: sheet.preview !== null; text: qsTr("Öffnen …"); onClicked: AppModel.quickLook(sheet.preview) }
            Button { visible: sheet.preview !== null; text: qsTr("Schließen"); onClicked: sheet.preview = null }
            Button { visible: sheet.canFetch && sheet.preview === null; text: qsTr("Kontoauszüge abrufen"); icon.name: SF.icon("arrow.down.doc")
                     enabled: AppModel.statementsAccountID !== (sheet.account ? sheet.account.id : -1) && AppModel.syncingConnectionID === null
                     onClicked: { AppModel.fetchStatements(sheet.account); sheet.close() } }
            Button { visible: sheet.preview === null; text: qsTr("Fertig"); highlighted: true; onClicked: sheet.close() }
        }
        ColumnLayout {
            visible: sheet.canFetch && sheet.preview === null
            spacing: 3; Layout.fillWidth: true
            Switch { id: auto; text: qsTr("Kontoauszüge automatisch beim Sync abrufen")
                     checked: sheet.account ? AppModel.autoStatements(sheet.account) : false
                     onToggled: AppModel.setAutoStatements(sheet.account, checked) }
            Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption; color: Theme.secondary
                   text: qsTr("Höchstens einmal pro Woche. Je nach Bank ist dafür eine zusätzliche TAN nötig. Ist ein Dokumentenordner eingestellt, landen die PDFs auch dort.") }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }
        DocumentPreview { visible: sheet.preview !== null; doc: sheet.preview; Layout.fillWidth: true; Layout.preferredHeight: 520 }
        ColumnLayout {
            visible: sheet.preview === null && sheet.docs.length === 0
            Layout.fillWidth: true; Layout.preferredHeight: 260; spacing: 8
            Item { Layout.fillHeight: true }
            SFIcon { Layout.alignment: Qt.AlignHCenter; symbol: "doc.text"; size: 30 }
            Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("Keine Dokumente"); font.pixelSize: Theme.title3 + 1; font.weight: Font.Bold; color: Theme.text }
            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; color: Theme.secondary
                   text: sheet.canFetch ? qsTr("Mit „Kontoauszüge abrufen“ lädt GiroCrab die PDF-Kontoauszüge per FinTS (ggf. mit TAN).")
                                        : qsTr("Importierte oder abgelegte Dokumente dieses Kontos erscheinen hier.") }
            Item { Layout.fillHeight: true }
        }
        ListView {
            visible: sheet.preview === null && sheet.docs.length > 0
            Layout.fillWidth: true; Layout.preferredHeight: 320
            clip: true
            model: sheet.docs
            delegate: ItemDelegate {
                required property var modelData
                width: ListView.view.width
                contentItem: RowLayout { spacing: 10
                    SFIcon { symbol: AppModel.docSymbol(modelData); size: 16; color: Theme.accent; Layout.preferredWidth: 20 }
                    ColumnLayout { spacing: 1; Layout.fillWidth: true
                        Text { text: modelData.title; color: Theme.text; elide: Text.ElideRight; Layout.fillWidth: true }
                        Text { text: Fmt.medium(modelData.doc_date) + " · " + AppModel.byteCount(modelData.size_bytes); font.pixelSize: Theme.caption2; color: Theme.secondary } }
                    SFIcon { symbol: "chevron.right"; size: 10 } }
                onClicked: sheet.preview = modelData
            }
        }
    }
}
