import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The dialogs behind a category's context menu (SidebarView.swift › categoryMenu):
// "Kategorie umbenennen" (AccountGroupDialogs' text alert) and the
// "Kategorie „…“ löschen?" confirmation (SidebarDialog.deleteCategory).
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

    // SidebarDialog.deleteCategory: the same form as the account dialogs (#669)
    ConfirmDialog {
        id: del
        readonly property var category: AppModel.deleteCategoryTarget
        property var current: null
        visible: category !== null
        parent: Overlay.overlay
        onAboutToShow: current = category
        onClosed: AppModel.deleteCategoryTarget = null
        heading: current ? qsTr("Kategorie „%1“ löschen?").arg(current.name) : ""
        message: qsTr("Die Kategorie wird samt ihren Unterkategorien und Regeln unwiderruflich gelöscht. Zugeordnete Buchungen bleiben erhalten und stehen danach ohne Kategorie da.")
        actionTitle: qsTr("Löschen")
        onConfirmed: AppModel.deleteCategory(current.id)
    }
}
