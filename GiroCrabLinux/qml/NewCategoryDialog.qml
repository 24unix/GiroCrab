import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// NewCategoryDialog.swift › NewCategorySheet: name, symbol and colour of a new
// category, driven by `AppModel.newCategoryRequest` ({ parent: id | null }).
// Changing an existing category goes through its context menu.
Sheet {
    id: sheet
    readonly property var request: AppModel.newCategoryRequest
    readonly property var parentId: request ? request.parent : null
    property string symbol: "tag.fill"
    property string colorHex: "#7A808A"
    readonly property string trimmed: nameField.text.trim()
    visible: request !== null
    sheetWidth: 440
    onAboutToShow: {
        nameField.text = ""
        symbol = "tag.fill"
        colorHex = "#7A808A"
        // a sub-category starts with its main category's colour
        const p = AppModel.categoryByID(parentId)
        if (p) colorHex = p.color_hex.toUpperCase()
        nameField.forceActiveFocus()
    }
    onClosed: AppModel.newCategoryRequest = null
    function create() {
        if (trimmed === "") return
        AppModel.createCategory(trimmed, parentId, symbol, colorHex)
        close()
    }

    ColumnLayout {
        width: sheet.availableWidth
        spacing: 14
        Text {
            text: sheet.parentId === null ? qsTr("Neue Hauptkategorie") : qsTr("Neue Unterkategorie")
            font.pixelSize: Theme.title3; font.weight: Font.Bold; color: Theme.text
        }
        GridLayout {
            Layout.fillWidth: true
            columns: 2; columnSpacing: 12; rowSpacing: 10
            Text { text: qsTr("Name"); font.pixelSize: Theme.body; color: Theme.text }
            TextField { id: nameField; Layout.fillWidth: true; onAccepted: sheet.create() }
            Text { text: qsTr("Symbol"); font.pixelSize: Theme.body; color: Theme.text }
            // SymbolPickerButton: opens the picker in a popup anchored to the button
            Rectangle {
                id: symbolButton
                implicitWidth: 28; implicitHeight: 24; radius: 6
                color: Theme.withAlpha(Theme.readable(sheet.colorHex), 0.15)
                SFIcon { anchors.centerIn: parent; symbol: sheet.symbol; size: 15; color: Theme.readable(sheet.colorHex) }
                TapHandler { onTapped: symbolPopup.open() }
                Accessible.name: qsTr("Symbol wählen")
                Popup {
                    id: symbolPopup
                    x: symbolButton.width + 6; y: -40
                    padding: 0
                    background: Rectangle { color: Theme.card; radius: 10; border.color: Theme.border }
                    SymbolPicker {
                        selection: sheet.symbol
                        tint: Theme.readable(sheet.colorHex)
                        onPicked: s => { sheet.symbol = s; symbolPopup.close() }
                    }
                }
            }
            Text { text: qsTr("Farbe"); font.pixelSize: Theme.body; color: Theme.text; Layout.alignment: Qt.AlignTop; topPadding: 4 }
            ColorSwatches {
                Layout.fillWidth: true
                Layout.maximumWidth: 240
                selection: sheet.colorHex
                onChosen: hex => sheet.colorHex = hex
            }
        }
        Text {
            readonly property var path: AppModel.categoryPath(sheet.parentId)
            visible: path !== null
            text: path !== null ? qsTr("Wird angelegt unter „%1“.").arg(path) : ""
            font.pixelSize: Theme.caption; color: Theme.secondary; wrapMode: Text.WordWrap; Layout.fillWidth: true
        }
        RowLayout {
            Layout.fillWidth: true
            Item { Layout.fillWidth: true }
            Button { text: qsTr("Abbrechen"); onClicked: sheet.close() }
            Button { text: qsTr("Anlegen"); highlighted: true; enabled: sheet.trimmed !== ""; onClicked: sheet.create() }
        }
    }
}
