import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// AccountSelectionView.swift › AccountSelectionPanel (#346): title, explanation, the list
// and "Später". Used as a sheet (AccountSelectionSheet.qml) and inside a running portal
// fetch, before documents are downloaded (WebLoginSheet.qml, FNZ).
ColumnLayout {
    id: panel
    property var connection: null
    signal done()
    spacing: 0

    ColumnLayout {
        Layout.fillWidth: true
        Layout.margins: 20
        spacing: 6
        Text {
            Layout.fillWidth: true; wrapMode: Text.WordWrap
            text: qsTr("Konten auswählen – %1").arg(panel.connection ? panel.connection.display_name : "")
            font.pixelSize: Theme.title3; font.weight: Font.Bold; color: Theme.text
        }
        Text {
            Layout.fillWidth: true; wrapMode: Text.WordWrap
            text: qsTr("Einige Konten sind bereits über einen anderen Zugang eingebunden. Wählen Sie, welche über diesen Zugang abgerufen werden sollen. Ohne Auswahl werden sie übersprungen.")
            font.pixelSize: Theme.callout; color: Theme.secondary
        }
    }
    Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }
    ScrollView {
        ScrollBar.vertical: ScrollViewBar {}
        id: scroll
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.preferredHeight: Math.min(box.implicitHeight + 40, 420)
        contentWidth: availableWidth
        clip: true
        Item {
            width: scroll.availableWidth
            implicitHeight: box.implicitHeight + 40
            FormSection {
                id: box
                x: 20; y: 20
                width: parent.width - 40
                boxColor: Theme.card
                AccountSelectionList {
                    connection: panel.connection
                    saveTitle: qsTr("Übernehmen und fortfahren")
                    onSaved: panel.done()
                }
            }
        }
    }
    Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }
    RowLayout {
        Layout.fillWidth: true
        Layout.margins: 14
        Item { Layout.fillWidth: true }
        Button { text: qsTr("Später"); onClicked: panel.done() }
    }
}
