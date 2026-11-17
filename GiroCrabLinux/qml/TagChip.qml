import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// TagsUI.swift › TagChip: colour dot and name; `removable` adds an ✕, `tappable` makes the chip
// a button. `partial` (multiple selection): only some of the bookings carry it (dashed edge).
// `highlighted`: the suggestion Return would add.
Item {
    id: chip
    property string name
    property string colorHex
    property bool partial: false
    property bool highlighted: false
    property bool tappable: false
    property bool removable: false
    /// Wraps (two lines, then „…“) instead of growing wider than this.
    property real maxWidth: 100000
    property string toolTip: ""
    signal tapped()
    signal removed()

    readonly property color tint: colorHex === "" ? Theme.secondary : colorHex
    implicitWidth: Math.min(maxWidth, row.implicitWidth + 14)
    implicitHeight: row.implicitHeight + 6
    width: implicitWidth

    // a capsule on one line; stays round-cornered when a long name takes two
    Rectangle {
        id: shape
        anchors.fill: parent
        radius: 10
        color: Theme.withAlpha(chip.tint, chip.partial ? 0.06 : 0.14)
        border.width: chip.partial ? 0 : (chip.highlighted ? 2 : 1)
        border.color: Theme.withAlpha(chip.tint, chip.highlighted ? 1 : 0.5)
    }
    // dashed edge of a partial chip
    DashedFrame {
        anchors.fill: parent
        visible: chip.partial
        radius: 10; lineWidth: 1; dash: [3, 2]
        strokeColor: Theme.withAlpha(chip.tint, 0.35)
    }
    RowLayout {
        id: row
        x: 7; y: 3
        width: chip.width - 14
        spacing: 4
        Rectangle { implicitWidth: 6; implicitHeight: 6; radius: 3; color: chip.tint; Layout.alignment: Qt.AlignVCenter }
        // long names: a second line, then „…“ (the inspector keeps its width)
        Text {
            text: chip.name
            font.pixelSize: Theme.caption
            color: chip.partial ? Theme.secondary : Theme.text
            wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
            Layout.fillWidth: true; Layout.maximumWidth: Math.ceil(implicitWidth)
            Sensitive {}
        }
        Text {
            id: removeMark
            visible: chip.removable
            text: "✕"
            font.pixelSize: Theme.caption2 - 1; font.weight: Font.Bold
            color: removeHover.hovered ? Theme.text : Theme.secondary
            Accessible.role: Accessible.Button
            Accessible.name: qsTr("„%1“ entfernen").arg(chip.name)
            HoverHandler { id: removeHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: chip.removed() }
        }
    }
    HoverHandler { id: hover; enabled: chip.tappable || chip.toolTip !== ""; cursorShape: chip.tappable ? Qt.PointingHandCursor : Qt.ArrowCursor }
    TapHandler {
        enabled: chip.tappable
        // the ✕ has its own handler
        onTapped: (point) => {
            const p = removeMark.mapFromItem(chip, point.position.x, point.position.y)
            if (!(removeMark.visible && removeMark.contains(p))) chip.tapped()
        }
    }
    ToolTip.visible: hover.hovered && toolTip !== "" && !removeHover.hovered
    ToolTip.delay: 600
    ToolTip.text: toolTip
}
