import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The dialogs behind a category's context menu (SidebarView.swift › categoryMenu):
// "Kategorie umbenennen" (AccountGroupDialogs' text alert) and the
// "Kategorie löschen?" confirmation (SidebarDialog.deleteCategory).
Item {
    Sheet {
        id: rename
        readonly property var category: AppModel.renameCategoryTarget
        visible: category !== null
        sheetWidth: 340
        parent: Overlay.overlay
        onAboutToShow: { field.text = category.name; field.selectAll(); field.forceActiveFocus() }
        onClosed: AppModel.renameCategoryTarget = null
        function submit() {
            const c = category
            const name = field.text.trim()
            if (name === "") return
            close()
            AppModel.renameCategory(c.id, name)
        }
        ColumnLayout {
            width: rename.availableWidth
            spacing: 12
            Text { text: qsTr("Kategorie umbenennen"); font.pixelSize: Theme.body + 1; font.weight: Font.Bold; color: Theme.text; Layout.alignment: Qt.AlignHCenter }
            TextField { id: field; Layout.fillWidth: true; placeholderText: qsTr("Name, z. B. „Privat“ oder „Geschäft“"); onAccepted: rename.submit() }
            RowLayout {
                Layout.fillWidth: true
                Button { text: qsTr("Abbrechen"); Layout.fillWidth: true; onClicked: rename.close() }
                Button { text: qsTr("Umbenennen"); highlighted: true; Layout.fillWidth: true; enabled: field.text.trim() !== ""; onClicked: rename.submit() }
            }
        }
    }

    Sheet {
        id: del
        readonly property var category: AppModel.deleteCategoryTarget
        visible: category !== null
        sheetWidth: 340
        parent: Overlay.overlay
        onClosed: AppModel.deleteCategoryTarget = null
        ColumnLayout {
            width: del.availableWidth
            spacing: 12
            Text { text: qsTr("Kategorie löschen?"); font.pixelSize: Theme.body + 1; font.weight: Font.Bold; color: Theme.text; Layout.alignment: Qt.AlignHCenter }
            Button {
                Layout.fillWidth: true
                text: del.category ? qsTr("„%1“ löschen").arg(AppModel.menuText(del.category.name)) : ""
                palette.buttonText: Theme.negative
                onClicked: { const id = del.category.id; del.close(); AppModel.deleteCategory(id) }
            }
            Button { Layout.fillWidth: true; text: qsTr("Abbrechen"); onClicked: del.close() }
        }
    }
}
