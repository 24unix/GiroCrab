import QtQuick
import QtQuick.Controls

// TagsUI.swift › TagOverflowBadge's popover: every tag of a booking as coloured chips, only as
// large as the chips need (one row for a few short tags, at most 260 pt wide).
Popup {
    id: pop
    property var tags: []
    padding: 8
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    readonly property real maxLineWidth: 260 * Theme.textScale
    /// The widest row of chips (Flow wraps at maxLineWidth).
    contentWidth: Math.min(maxLineWidth, flow.childrenWidth)
    contentHeight: flow.implicitHeight
    background: Rectangle { radius: 9; color: Theme.card; border.color: Theme.border }
    Flow {
        id: flow
        width: pop.maxLineWidth
        spacing: 6
        readonly property real childrenWidth: {
            let w = 0, line = 0
            for (let i = 0; i < repeater.count; ++i) {
                const c = repeater.itemAt(i)
                if (!c) continue
                line = line === 0 ? c.width : line + spacing + c.width
                if (line > pop.maxLineWidth) line = c.width
                w = Math.max(w, line)
            }
            return w
        }
        Repeater {
            id: repeater
            model: pop.tags
            TagChip { required property var modelData; name: modelData.name; colorHex: modelData.color_hex; maxWidth: pop.maxLineWidth }
        }
    }
}
