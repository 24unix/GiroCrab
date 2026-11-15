import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// RuleEditorView.swift: keyword / regex / search-expression auto-categorisation
// rules with live preview. Rule list on the left, RuleForm on the right.
Sheet {
    id: editor
    visible: AppModel.showRuleEditor
    sheetWidth: 900
    padding: 0
    property var selection: null   // rule id
    property var draft: null       // Rule being edited
    /// Rule waiting for the delete confirmation.
    property var ruleToDelete: null

    onAboutToShow: {
        const d = AppModel.ruleDraft
        draft = d
        selection = d && d.id !== 0 ? d.id : null
        AppModel.ruleDraft = null
    }
    onClosed: { AppModel.showRuleEditor = false; draft = null; selection = null }

    function color(rule) { const c = AppModel.categoryByID(rule.category_id); return c ? c.color_hex : "#8E8E93" }
    function categoryName(id) { const c = AppModel.categoryByID(id); return c ? c.path : "?" }
    function select(rule) { selection = rule.id; draft = Object.assign({}, rule) }
    function newRule() { selection = null; draft = AppModel.newRuleDraft(null) }
    function save(rule) {
        const id = AppModel.saveRule(rule)
        if (id !== null) {
            selection = id
            const r = AppModel.rules.find(r => r.id === id)
            draft = r ? Object.assign({}, r) : draft
        }
    }
    function remove(rule) {
        AppModel.deleteRule(rule.id)
        selection = null
        draft = null
    }

    Item {
        width: editor.availableWidth
        height: Math.min(620, (editor.parent ? editor.parent.height : 700) - 40)
        ColumnLayout {
            anchors.fill: parent
            spacing: 0
            // toolbar: title + "Neue Regel" over the list, "Alle Regeln anwenden" and "Fertig" over the detail
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 44
                spacing: 6
                Item { implicitWidth: 8 }
                Text { text: qsTr("Regeln"); font.pixelSize: Theme.title3; font.weight: Font.Bold; color: Theme.text; Layout.preferredWidth: 230 - 36 }
                IconButton { symbol: "plus"; ToolTip.text: qsTr("Neue Regel"); Accessible.name: qsTr("Neue Regel"); onClicked: editor.newRule() }
                Item { Layout.fillWidth: true }
                IconButton { symbol: "play.fill"; text: qsTr("Alle Regeln anwenden"); onClicked: AppModel.applyAllRules() }
                Button { text: qsTr("Fertig"); highlighted: true; onClicked: editor.close() }
                Item { implicitWidth: 8 }
            }
            Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0
                // rule list
                ListView {
                    id: list
                    Layout.preferredWidth: 260
                    Layout.fillHeight: true
                    clip: true
                    topMargin: 6; bottomMargin: 6
                    model: AppModel.rules
                    ScrollBar.vertical: AppScrollBar {}
                    delegate: Item {
                        id: rr
                        required property var modelData
                        readonly property bool selected: editor.selection === modelData.id
                        width: ListView.view.width; height: 44
                        Rectangle {
                            anchors.fill: parent; anchors.leftMargin: 6; anchors.rightMargin: 6
                            radius: 6
                            color: rr.selected ? Theme.selection : (rh.hovered ? Theme.withAlpha(Theme.secondary, 0.07) : "transparent")
                        }
                        HoverHandler { id: rh }
                        TapHandler { onTapped: editor.select(rr.modelData) }
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 8
                            SFIcon { symbol: rr.modelData.enabled ? "wand.and.stars" : "pause.circle"; size: 16
                                     color: rr.modelData.enabled ? Theme.readable(editor.color(rr.modelData)) : Theme.secondary }
                            ColumnLayout {
                                spacing: 1; Layout.fillWidth: true
                                Text { text: rr.modelData.name; font.pixelSize: Theme.body; color: Theme.text; elide: Text.ElideRight; Layout.fillWidth: true }
                                Text { text: "→ " + editor.categoryName(rr.modelData.category_id); font.pixelSize: Theme.caption; color: Theme.secondary; elide: Text.ElideRight; Layout.fillWidth: true }
                            }
                            Rectangle {
                                implicitWidth: cnt.implicitWidth + 12; implicitHeight: cnt.implicitHeight + 2; radius: height / 2
                                color: Theme.withAlpha(Theme.secondary, 0.15)
                                Text { id: cnt; anchors.centerIn: parent; text: rr.modelData.match_count; font.pixelSize: Theme.caption; font.features: { "tnum": 1 }; color: Theme.text }
                            }
                        }
                    }
                }
                Rectangle { Layout.fillHeight: true; width: 1; color: Theme.border }
                // detail
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    RuleForm {
                        anchors.fill: parent
                        visible: editor.draft !== null
                        rule: editor.draft
                        onEdited: r => editor.draft = r
                        onSaveRequested: r => editor.save(r)
                        onDeleteRequested: r => editor.ruleToDelete = r
                    }
                    // ContentUnavailableView
                    ColumnLayout {
                        visible: editor.draft === null
                        anchors.centerIn: parent
                        width: Math.min(parent.width - 80, 420)
                        spacing: 10
                        SFIcon { symbol: "wand.and.stars"; size: 40; Layout.alignment: Qt.AlignHCenter }
                        Text { text: qsTr("Keine Regel ausgewählt"); font.pixelSize: Theme.title3 + 2; font.weight: Font.Bold; color: Theme.text; Layout.alignment: Qt.AlignHCenter }
                        Text {
                            text: qsTr("Regeln ordnen neue Buchungen automatisch Kategorien zu. Die erste passende Regel (nach Priorität) gewinnt; manuelle Zuordnungen werden nie überschrieben.")
                            font.pixelSize: Theme.body; color: Theme.secondary; wrapMode: Text.WordWrap
                            horizontalAlignment: Text.AlignHCenter; Layout.fillWidth: true
                        }
                    }
                }
            }
        }
    }

    // .confirmationDialog("Regel löschen?")
    Sheet {
        id: confirm
        visible: editor.ruleToDelete !== null
        sheetWidth: 360
        parent: Overlay.overlay
        onClosed: editor.ruleToDelete = null
        ColumnLayout {
            width: confirm.availableWidth
            spacing: 12
            Text { text: qsTr("Regel löschen?"); font.pixelSize: Theme.body + 1; font.weight: Font.Bold; color: Theme.text; Layout.alignment: Qt.AlignHCenter }
            Text {
                text: qsTr("Buchungen, die diese Regel kategorisiert hat, sind danach wieder ohne Kategorie. Das lässt sich nicht widerrufen.")
                font.pixelSize: Theme.callout + 1; color: Theme.secondary; wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter; Layout.fillWidth: true
            }
            Button {
                Layout.fillWidth: true; text: qsTr("Löschen"); palette.buttonText: Theme.negative
                onClicked: { const r = editor.ruleToDelete; confirm.close(); editor.remove(r) }
            }
            Button { Layout.fillWidth: true; text: qsTr("Abbrechen"); onClicked: confirm.close() }
        }
    }
}
