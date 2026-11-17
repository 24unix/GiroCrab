import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// TagsUI.swift › TagEntryField: text field that adds a tag (an existing one or a new name) plus
// suggestions – every existing tag matching the text; while empty the first ones and
// „+n weitere“, which unfolds all of them. Below the field a hint says what Return will do.
ColumnLayout {
    id: entry
    /// Tags already carried by every booking: { id: true }, not suggested.
    property var carried: ({})
    /// Several bookings: the hint says „bei allen“.
    property bool multiple: false
    signal add(string name)
    spacing: 6

    /// Suggestions shown while the field is empty and folded.
    readonly property int foldedCount: 8
    property bool showsAll: false
    readonly property string trimmed: TagsModel.cleanTagName(field.text)
    readonly property var intent: TagsModel.entryIntent(field.text, carried)
    readonly property var open: TagsModel.tags.filter(t => !carried[t.id])
    readonly property var suggestions: trimmed === "" ? (showsAll ? open : open.slice(0, foldedCount))
                                                      : TagsModel.suggestions(field.text, carried)
    /// Coloured edge only when something needs a look: orange already set or a look-alike exists, red too long.
    readonly property color edgeColor: intent.kind === "already" || intent.kind === "similar" ? Theme.warning
                                     : intent.kind === "tooLong" ? Theme.negative : "transparent"
    readonly property string hint: {
        switch (intent.kind) {
        case "create": return qsTr("↩ legt „%1“ neu an").arg(intent.name)
        case "add": return qsTr("↩ fügt „%1“ hinzu").arg(intent.name)
        case "already": return multiple ? qsTr("„%1“ ist schon bei allen gesetzt").arg(intent.name) : qsTr("„%1“ ist schon gesetzt").arg(intent.name)
        case "similar": return qsTr("Ähnlich wie „%1“ – ↩ legt trotzdem neu an").arg(intent.existing)
        case "tooLong": return qsTr("Höchstens %1 Zeichen").arg(TagsModel.maxTagNameLength)
        }
        return ""
    }

    function focusField() { field.forceActiveFocus() }
    function addNow(name) { entry.add(name); field.text = "" }
    /// Return: only when it creates or adds something; otherwise the text and the hint stay.
    function submit() {
        if (["create", "add", "similar"].indexOf(intent.kind) >= 0) addNow(intent.name)
    }

    TextField {
        id: field
        Layout.fillWidth: true
        placeholderText: qsTr("Tag hinzufügen …")
        font.pixelSize: Theme.callout + 1
        onAccepted: entry.submit()
        Keys.onEscapePressed: { field.text = ""; AppModel.focusList() }
        Rectangle {
            anchors.fill: parent; radius: 6; color: "transparent"
            visible: entry.edgeColor.a > 0
            border.color: entry.edgeColor; border.width: 1.5
        }
        Sensitive {}
    }
    // what Return will do, readable at a glance while typing
    Text {
        visible: entry.hint !== ""
        text: entry.hint
        Layout.fillWidth: true
        font.pixelSize: Theme.caption
        color: entry.edgeColor.a > 0 ? entry.edgeColor : Theme.secondary
        wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideMiddle
        Sensitive {}
    }
    Flow {
        id: flow
        visible: entry.suggestions.length > 0
        Layout.fillWidth: true
        spacing: 6
        Repeater {
            model: entry.suggestions
            TagChip {
                required property var modelData
                name: modelData.name
                colorHex: modelData.color_hex
                maxWidth: flow.width
                highlighted: (entry.intent.kind === "add" || entry.intent.kind === "similar") && entry.intent.id === modelData.id
                tappable: true
                toolTip: qsTr("Tag hinzufügen")
                onTapped: entry.addNow(modelData.name)
            }
        }
        Text {
            visible: entry.trimmed === "" && entry.open.length > entry.foldedCount
            text: entry.showsAll ? qsTr("Weniger") : qsTr("+%1 weitere").arg(entry.open.length - entry.foldedCount)
            font.pixelSize: Theme.caption; font.weight: Font.Medium; color: Theme.accent
            topPadding: 3; bottomPadding: 3; leftPadding: 4; rightPadding: 4
            HoverHandler { cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: entry.showsAll = !entry.showsAll }
        }
    }
}
