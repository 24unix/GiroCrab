import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects

// InspectorLayoutEditor.swift › InspectorLayoutEditor (#448): edit mode of the inspector. Drag a
// card to reorder it (blue insertion line), hide it with ⊖, show it again with ⊕ from the
// „Ausgeblendet“ list below. The Mac's VoiceOver actions „Nach oben“ / „Nach unten“ are the keys
// ↑ / ↓ here: a click on a card selects it for the keyboard.
ColumnLayout {
    id: editor
    /// (section id) → Component of that card for the selected booking (InspectorView.cardComponent).
    property var cardComponent: id => null
    property var booking: null
    /// The scroll view around the editor: scrolled while a card is dragged near its edges.
    property Flickable flickable: null
    spacing: 14

    readonly property var shown: InspectorLayout.shown
    /// Section being dragged ("" = none) and the gap of the visible list a drop would land in.
    property string dragged: ""
    property int dropGap: -1
    property bool hiddenAreaTargeted: false
    /// The card that ↑ / ↓ move.
    property string keyboardSection: ""
    readonly property string dragKey: "girocrab.inspector-section"

    function moveBy(id, delta) {
        const i = shown.indexOf(id)
        if (i < 0 || i + delta < 0 || i + delta >= shown.length) return
        InspectorLayout.move(id, i + delta)
    }

    // empty visible list: drop here to show a section
    DropHint {
        visible: editor.shown.length === 0
        Layout.fillWidth: true
        text: qsTr("Bereiche hierher ziehen, um sie einzublenden")
        highlighted: editor.dropGap === 0
        DropArea {
            anchors.fill: parent; keys: [editor.dragKey]
            onEntered: editor.dropGap = 0
            onExited: if (editor.dropGap === 0) editor.dropGap = -1
            onDropped: { editor.dropGap = -1; InspectorLayout.insert(editor.dragged, 0) }
        }
    }
    Repeater {
        model: editor.shown
        EditableCard {
            id: shownCard
            required property string modelData
            required property int index
            section: modelData
            isHidden: false
            Layout.fillWidth: true
            onToggle: InspectorLayout.hide(modelData)
            // upper half drops above this card, lower half below it
            Column {
                anchors.fill: parent
                Repeater {
                    model: 2
                    DropArea {
                        required property int index
                        readonly property int gap: shownCard.index + index
                        width: parent.width; height: parent.height / 2
                        keys: [editor.dragKey]
                        onEntered: editor.dropGap = gap
                        onExited: if (editor.dropGap === gap) editor.dropGap = -1
                        onDropped: { editor.dropGap = -1; InspectorLayout.insert(editor.dragged, gap) }
                    }
                }
            }
            InsertionLine { visible: editor.dropGap === shownCard.index; y: -8.5 - height / 2 }
            InsertionLine { visible: shownCard.index === editor.shown.length - 1 && editor.dropGap === editor.shown.length
                            y: parent.height + 8.5 - height / 2 }
        }
    }

    // hiddenArea: the whole area below „Ausgeblendet“ (behind its cards) takes a drop to hide
    Item {
        Layout.fillWidth: true
        implicitHeight: hiddenArea.implicitHeight
        DropArea {
            anchors.fill: parent
            keys: [editor.dragKey]
            onEntered: editor.hiddenAreaTargeted = true
            onExited: editor.hiddenAreaTargeted = false
            onDropped: { editor.hiddenAreaTargeted = false; InspectorLayout.hide(editor.dragged) }
        }
        ColumnLayout {
            id: hiddenArea
            width: parent.width
            spacing: 14
            Text { text: qsTr("Ausgeblendet"); font.pixelSize: Theme.caption; font.weight: Font.DemiBold; color: Theme.secondary
                   Layout.topMargin: 8 }
            DropHint {
                visible: InspectorLayout.hiddenSections.length === 0
                Layout.fillWidth: true
                text: qsTr("Bereiche hierher ziehen oder mit ⊖ ausblenden")
                highlighted: editor.hiddenAreaTargeted
            }
            Repeater {
                model: InspectorLayout.hiddenSections
                EditableCard {
                    required property string modelData
                    section: modelData
                    isHidden: true
                    Layout.fillWidth: true
                    onToggle: InspectorLayout.show(modelData)
                }
            }
        }
    }

    // the drag image: the section's symbol and title
    Rectangle {
        id: ghost
        // above everything, in window coordinates (a child of the layout would be laid out)
        parent: Overlay.overlay
        visible: editor.dragged !== ""
        z: 1000
        width: ghostRow.implicitWidth + 24; height: ghostRow.implicitHeight + 16
        radius: 8; color: Theme.card; border.color: Theme.border
        RowLayout {
            id: ghostRow
            anchors.centerIn: parent; spacing: 6
            SFIcon { symbol: InspectorLayout.section(editor.dragged || "receipt").symbol; size: 14; color: Theme.text }
            Text { text: InspectorLayout.section(editor.dragged || "receipt").title; font.pixelSize: Theme.callout + 1; font.weight: Font.DemiBold; color: Theme.text }
        }
        Drag.active: editor.dragged !== ""
        Drag.keys: [editor.dragKey]
        Drag.hotSpot.x: 12; Drag.hotSpot.y: height / 2
        Drag.dragType: Drag.Internal
    }
    // keeps the dragged card reachable: scroll while the pointer is near the top or bottom edge
    Timer {
        interval: 30; repeat: true
        running: editor.dragged !== "" && editor.flickable !== null
        onTriggered: {
            const f = editor.flickable
            const p = f.mapFromItem(null, ghost.x + ghost.Drag.hotSpot.x, ghost.y + ghost.Drag.hotSpot.y)
            const step = p.y < 40 ? -12 : p.y > f.height - 40 ? 12 : 0
            if (step === 0) return
            const maxY = Math.max(0, f.contentHeight - f.height)
            const y = Math.max(0, Math.min(maxY, f.contentY + step))
            if (y === f.contentY) return
            f.contentY = y
            // the cards moved under the resting pointer: let the drop areas notice
            ghost.y += (ghost.y % 1 === 0) ? 0.01 : -0.01
        }
    }

    // InspectorEditableCard: content not interactive, the whole card can be dragged, a round ⊖
    // (visible) or ⊕ (hidden) button on its top-left corner. Hidden cards are drawn colourless,
    // faded and with a dashed frame, without changing their content.
    component EditableCard: Item {
        id: ec
        property string section
        property bool isHidden
        default property alias overlays: overlayLayer.data
        signal toggle()
        readonly property var info: InspectorLayout.section(section)
        implicitHeight: content.implicitHeight
        activeFocusOnTab: !isHidden
        Accessible.name: info ? info.title : ""
        Keys.onUpPressed: editor.moveBy(section, -1)
        Keys.onDownPressed: editor.moveBy(section, 1)
        opacity: editor.dragged === section ? 0.4 : 1

        Loader {
            id: content
            width: parent.width
            enabled: false
            sourceComponent: editor.cardComponent(ec.section, true)
            layer.enabled: ec.isHidden
            layer.effect: MultiEffect { saturation: -1 }
            opacity: ec.isHidden ? 0.45 : 1
        }
        // keyboard selection (↑ / ↓)
        Rectangle {
            anchors.fill: parent; radius: 12; color: "transparent"
            visible: ec.activeFocus; border.color: Theme.accent; border.width: 2
        }
        // dashed frame of a hidden card
        DashedFrame { anchors.fill: parent; visible: ec.isHidden; strokeColor: Theme.tertiary }
        Item {
            id: dragArea
            anchors.fill: parent
            DragHandler {
                id: dh
                target: null
                dragThreshold: 6
                // the scroll view must not take the drag over
                grabPermissions: PointerHandler.CanTakeOverFromAnything
                onActiveChanged: {
                    if (active) {
                        editor.dragged = ec.section
                        ec.forceActiveFocus()
                    } else {
                        // the drop rebuilds the card list, this card included: keep the references
                        const ed = editor, g = ghost
                        g.Drag.drop()
                        ed.dragged = ""
                        ed.dropGap = -1
                        ed.hiddenAreaTargeted = false
                    }
                }
                onCentroidChanged: if (active) {
                    ghost.x = centroid.scenePosition.x - ghost.Drag.hotSpot.x
                    ghost.y = centroid.scenePosition.y - ghost.Drag.hotSpot.y
                }
            }
            TapHandler { onTapped: if (!ec.isHidden) ec.forceActiveFocus() }
            HoverHandler { cursorShape: dh.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor }
        }
        // drop zones (visible cards) and insertion lines
        Item { id: overlayLayer; anchors.fill: parent }
        // ⊖ / ⊕
        Rectangle {
            id: toggleButton
            x: -8; y: -8; width: 20; height: 20; radius: 10
            color: ec.isHidden ? Theme.inflow : Theme.negative
            layer.enabled: true
            layer.effect: MultiEffect { shadowEnabled: true; shadowColor: "#000000"; shadowOpacity: 0.2; shadowBlur: 0.1; shadowVerticalOffset: 0.5 }
            Rectangle { anchors.centerIn: parent; width: 10; height: 2; radius: 1; color: "white" }
            Rectangle { visible: ec.isHidden; anchors.centerIn: parent; width: 2; height: 10; radius: 1; color: "white" }
            readonly property string tip: ec.isHidden ? qsTr("„%1“ einblenden").arg(ec.info ? ec.info.title : "")
                                                      : qsTr("„%1“ ausblenden").arg(ec.info ? ec.info.title : "")
            Accessible.role: Accessible.Button
            Accessible.name: tip
            HoverHandler { id: toggleHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: ec.toggle() }
            ToolTip.visible: toggleHover.hovered; ToolTip.delay: 600; ToolTip.text: tip
        }
    }

    // InspectorDropHint: dashed drop area shown where nothing is listed yet.
    component DropHint: Item {
        id: hint
        property string text
        property bool highlighted
        implicitHeight: Math.max(56, hintText.implicitHeight + 16)
        Rectangle { anchors.fill: parent; radius: 12; color: hint.highlighted ? Theme.selection : "transparent" }
        DashedFrame { anchors.fill: parent; strokeColor: hint.highlighted ? Theme.accent : Theme.border }
        Text {
            id: hintText
            anchors.centerIn: parent; width: parent.width - 24
            text: hint.text; wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter
            font.pixelSize: Theme.caption; color: Theme.secondary
        }
    }

    // InsertionLine: blue line marking where a dragged card will be inserted.
    component InsertionLine: Rectangle {
        x: 4; width: parent ? parent.width - 8 : 0; height: 3; radius: 1.5
        color: Theme.accent
    }
}
