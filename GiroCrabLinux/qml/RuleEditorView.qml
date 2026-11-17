import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// RuleEditorView.swift: keyword / regex / search-expression auto-categorisation
// rules with live preview. Rule list on the left (filter, rank, drag & drop order,
// context menu), RuleForm on the right.
Sheet {
    id: editor
    visible: AppModel.showRuleEditor
    sheetWidth: 900
    padding: 0
    property var selection: null   // rule id
    property var draft: null       // Rule being edited
    /// Rule waiting for the delete confirmation.
    property var ruleToDelete: null
    /// The list filter (#435): tokens with * and ?.
    property string searchText: ""
    readonly property bool isFiltering: searchText.trim() !== ""
    readonly property var filteredRules: isFiltering
        ? AppModel.rules.filter(r => editor.matches(searchText, r.name, r.pattern, categoryName(r.category_id)))
        : AppModel.rules
    /// The rule a context menu was opened on.
    property var menuRule: null
    readonly property int menuIndex: menuRule ? AppModel.rules.findIndex(r => r.id === menuRule.id) : -1

    onAboutToShow: {
        const d = AppModel.ruleDraft
        draft = d
        selection = d && d.id !== 0 ? d.id : null
        AppModel.ruleDraft = null
    }
    onClosed: { AppModel.showRuleEditor = false; draft = null; selection = null; searchText = "" }

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

    // MARK: RuleSearchMatcher (#435)
    /// Every space-separated token matches name, pattern or category path (or all three joined),
    /// case-insensitively; `*` is any sequence, `?` one character.
    function matches(query, name, pattern, categoryPath) {
        const trimmed = query.trim()
        if (trimmed === "") return true
        const haystacks = [name || "", pattern || "", categoryPath || ""]
        const combined = haystacks.join(" ")
        return trimmed.split(/\s+/).every(token => haystacks.some(h => wildcardMatch(token, h)) || wildcardMatch(token, combined))
    }
    function wildcardMatch(token, text) {
        const p = token.toLowerCase()
        const t = text.toLowerCase()
        if (p === "") return true
        if (p.indexOf("*") < 0 && p.indexOf("?") < 0) return t.indexOf(p) >= 0
        const rx = p.split("").map(ch => ch === "*" ? ".*" : ch === "?" ? "." : ch.replace(/[.*+?^${}()|[\]\\\/-]/g, "\\$&")).join("")
        return new RegExp(rx).test(t)
    }

    // MARK: order (#434): the list order is the priority (AppModel+Editing.swift › reorderRules)
    function reorder(ordered) {
        AppModel.run(() => {
            ordered.forEach((rule, idx) => {
                const p = (idx + 1) * 10
                if (rule.priority !== p) AppModel.core("save_rule", { rule: Object.assign({}, rule, { priority: p }) })
            })
            AppModel.core("apply_rules", { only_uncategorized: false })
        })
        // the next move and the draft below need the new order now (reloadAll is async)
        AppModel.reloadRulesNow()
        AppModel.reloadAll()
        // the open draft gets the new priority, so saving it keeps the place
        if (selection !== null && draft !== null && draft.id === selection) {
            const r = AppModel.rules.find(r => r.id === selection)
            if (r) draft = Object.assign({}, draft, { priority: r.priority })
        }
    }
    /// RuleSearchMatcher.move(rules:id:to:)
    function moveRule(id, destination) {
        const copy = AppModel.rules.slice()
        const from = copy.findIndex(r => r.id === id)
        if (from < 0) return
        const item = copy.splice(from, 1)[0]
        copy.splice(Math.max(0, Math.min(destination, copy.length)), 0, item)
        reorder(copy)
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
                ColumnLayout {
                    Layout.preferredWidth: 280
                    Layout.maximumWidth: 280
                    Layout.fillWidth: false
                    Layout.fillHeight: true
                    spacing: 0
                    // the filter field above the list
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: 10; Layout.rightMargin: 10; Layout.topMargin: 7; Layout.bottomMargin: 7
                        spacing: 6
                        SFIcon { symbol: "magnifyingglass"; size: Theme.callout; color: Theme.secondary }
                        TextField {
                            id: filterField
                            Layout.fillWidth: true
                            padding: 0; leftPadding: 0; rightPadding: 0
                            background: null
                            placeholderText: qsTr("Regeln filtern (z. B. deu*b) …")
                            font.pixelSize: Theme.callout
                            color: Theme.text
                            text: editor.searchText
                            onTextEdited: editor.searchText = text
                            Keys.onEscapePressed: event => { if (text !== "") { editor.searchText = ""; event.accepted = true } else event.accepted = false }
                        }
                        IconButton {
                            visible: editor.searchText !== ""
                            symbol: "xmark.circle.fill"; symbolSize: Theme.callout
                            implicitWidth: 16; implicitHeight: 16
                            Accessible.name: qsTr("Filter zurücksetzen")
                            onClicked: editor.searchText = ""
                        }
                    }
                    Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }
                    // rule list
                    ListView {
                        id: list
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        topMargin: 6; bottomMargin: 6
                        model: editor.filteredRules
                        ScrollBar.vertical: AppScrollBar {}
                        /// Drag & drop (not while filtering): the dragged rule and the insertion row.
                        property var dragID: null
                        property int dropIndex: -1
                        delegate: Item {
                            id: rr
                            required property var modelData
                            required property int index
                            readonly property bool selected: editor.selection === modelData.id
                            readonly property int rank: AppModel.rules.findIndex(r => r.id === modelData.id) + 1
                            width: ListView.view.width; height: 44
                            opacity: list.dragID === modelData.id ? 0.5 : 1
                            Rectangle {
                                anchors.fill: parent; anchors.leftMargin: 6; anchors.rightMargin: 6
                                radius: 6
                                color: rr.selected ? Theme.selection : (rh.hovered ? Theme.withAlpha(Theme.secondary, 0.07) : "transparent")
                            }
                            HoverHandler { id: rh }
                            TapHandler { onTapped: editor.select(rr.modelData) }
                            TapHandler { acceptedButtons: Qt.RightButton; onTapped: { editor.menuRule = rr.modelData; ruleMenu.popup() } }
                            DragHandler {
                                enabled: !editor.isFiltering
                                target: null
                                yAxis.enabled: true; xAxis.enabled: false
                                onActiveChanged: {
                                    if (active) { list.dragID = rr.modelData.id; return }
                                    const id = list.dragID, to = list.dropIndex
                                    list.dragID = null; list.dropIndex = -1
                                    if (id === null || to < 0) return
                                    const from = AppModel.rules.findIndex(r => r.id === id)
                                    // `to` is the gap before row `to`; removing the row first shifts the later ones
                                    const dest = to > from ? to - 1 : to
                                    if (dest !== from) editor.moveRule(id, dest)
                                }
                                onCentroidChanged: {
                                    if (!active) return
                                    const p = rr.mapToItem(list.contentItem, centroid.position.x, centroid.position.y)
                                    const i = list.indexAt(10, p.y)
                                    if (i < 0) { list.dropIndex = p.y < 0 ? 0 : AppModel.rules.length; return }
                                    const item = list.itemAtIndex(i)
                                    list.dropIndex = item && p.y > item.y + item.height / 2 ? i + 1 : i
                                }
                            }
                            // the insertion line above this row (or below the last one)
                            Rectangle {
                                visible: list.dragID !== null && (list.dropIndex === rr.index || (list.dropIndex === list.count && rr.index === list.count - 1))
                                x: 14; width: parent.width - 28; height: 2; radius: 1
                                y: list.dropIndex === rr.index ? -1 : parent.height - 1
                                color: Theme.accent
                            }
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 8
                                Text { text: rr.rank + "."; font.pixelSize: Theme.caption; font.features: { "tnum": 1 }; color: Theme.secondary
                                       horizontalAlignment: Text.AlignRight; Layout.minimumWidth: 22 }
                                SFIcon { symbol: rr.modelData.enabled ? "wand.and.stars" : "pause.circle"; size: 16
                                         color: rr.modelData.enabled ? Theme.readable(editor.color(rr.modelData)) : Theme.secondary
                                         Accessible.name: rr.modelData.enabled ? "" : qsTr("Pausiert") }
                                ColumnLayout {
                                    spacing: 1; Layout.fillWidth: true
                                    // rule names are mostly payees ("Miete Müller")
                                    Text { text: rr.modelData.name; font.pixelSize: Theme.body; color: Theme.text; elide: Text.ElideRight; Layout.fillWidth: true; Sensitive {} }
                                    Text { text: "→ " + editor.categoryName(rr.modelData.category_id); font.pixelSize: Theme.caption; color: Theme.secondary; elide: Text.ElideRight; Layout.fillWidth: true
                                           Sensitive { labels: true } }
                                }
                                Rectangle {
                                    implicitWidth: cnt.implicitWidth + 12; implicitHeight: cnt.implicitHeight + 2; radius: height / 2
                                    color: Theme.withAlpha(Theme.secondary, 0.15)
                                    Accessible.name: qsTr("%1 Treffer").arg(rr.modelData.match_count)
                                    Text { id: cnt; anchors.centerIn: parent; text: rr.modelData.match_count; font.pixelSize: Theme.caption; font.features: { "tnum": 1 }; color: Theme.text }
                                }
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
                            text: qsTr("Regeln werden von oben nach unten ausgewertet – die erste passende Regel gewinnt. Reihenfolge per Drag & Drop in der Liste ändern.")
                            font.pixelSize: Theme.body; color: Theme.secondary; wrapMode: Text.WordWrap
                            horizontalAlignment: Text.AlignHCenter; Layout.fillWidth: true
                        }
                    }
                }
            }
        }
    }

    // the context menu of a rule row
    AppMenu {
        id: ruleMenu
        AppMenuItem { text: qsTr("An den Anfang"); icon.name: SF.icon("arrow.up.to.line"); enabled: editor.menuIndex > 0
                      onTriggered: editor.moveRule(editor.menuRule.id, 0) }
        AppMenuItem { text: qsTr("Nach oben"); icon.name: SF.icon("arrow.up"); enabled: editor.menuIndex > 0
                      onTriggered: editor.moveRule(editor.menuRule.id, editor.menuIndex - 1) }
        AppMenuItem { text: qsTr("Nach unten"); icon.name: SF.icon("arrow.down"); enabled: editor.menuIndex >= 0 && editor.menuIndex < AppModel.rules.length - 1
                      onTriggered: editor.moveRule(editor.menuRule.id, editor.menuIndex + 1) }
        AppMenuItem { text: qsTr("Ans Ende"); icon.name: SF.icon("arrow.down.to.line"); enabled: editor.menuIndex >= 0 && editor.menuIndex < AppModel.rules.length - 1
                      onTriggered: editor.moveRule(editor.menuRule.id, AppModel.rules.length - 1) }
        AppMenuSeparator {}
        AppMenuItem { text: qsTr("Regel löschen …"); icon.name: SF.icon("trash"); onTriggered: editor.ruleToDelete = editor.menuRule }
    }

    // .confirmationDialog("Regel löschen?")
    ConfirmDialog {
        id: confirm
        property var current: null
        visible: editor.ruleToDelete !== null
        parent: Overlay.overlay
        onAboutToShow: current = editor.ruleToDelete
        onClosed: editor.ruleToDelete = null
        heading: qsTr("Regel löschen?")
        message: qsTr("Buchungen, die diese Regel kategorisiert hat, sind danach wieder ohne Kategorie. Das lässt sich nicht widerrufen.")
        actionTitle: qsTr("Löschen")
        onConfirmed: editor.remove(current)
    }
}
