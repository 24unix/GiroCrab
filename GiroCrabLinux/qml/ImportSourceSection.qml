import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// MoneyMoneyImportSheet.swift › ImportSourceSection: where the data comes
// from, as radio buttons with a short explanation each. Identical on both
// assistants, so switching keeps the layout.
FormSection {
    id: s
    property string source              // "database" | "export"
    signal chosen(string source)
    title: qsTr("Quelle")
    Repeater {
        model: [
            { id: "database", title: qsTr("MoneyMoney-Datenbank"),
              detail: qsTr("Alle Konten mit Kategorien, Regeln, Bankzugängen und Kontoauszügen – empfohlen beim Umstieg.") },
            { id: "export", title: qsTr("Exportdatei eines Kontos"),
              detail: qsTr("CSV, camt.053 oder MT940 – um einzelne Konten zu ergänzen.") }
        ]
        RowLayout {
            required property var modelData
            Layout.fillWidth: true
            spacing: 4
            RadioButton {
                checked: s.source === modelData.id
                onClicked: s.chosen(modelData.id)
                Layout.alignment: Qt.AlignTop
            }
            ColumnLayout {
                spacing: 2
                Layout.fillWidth: true
                Text { text: modelData.title; color: Theme.text; font.pixelSize: Theme.body
                       MouseArea { anchors.fill: parent; enabled: s.enabled; onClicked: s.chosen(modelData.id) } }
                Text { text: modelData.detail; color: Theme.secondary; font.pixelSize: Theme.caption; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            }
        }
    }
}
