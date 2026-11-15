import QtQuick

// SidebarView.swift › DropSlot + GroupDrag: a sidebar row that can be dragged
// (account or user group) and that accepts drops above / below it or into a group.
// The drag state lives in AppModel (dragPayload, dragScenePos, dropLine).
Item {
    id: slot
    anchors.fill: parent
    property string key
    property string intoKey: key
    property real inset: 0
    property real freeLeading: 0
    /// What dragging this row carries: { type: "account", id } | { type: "group", uuid } | null.
    property var payload: null
    /// (half, dragged payload) → "above" | "below" | "into" | null
    property var edgeFor: (half, p) => half
    signal perform(var payload, string edge)

    DragHandler {
        id: dh
        enabled: slot.payload !== null
        target: null
        dragThreshold: 6
        onActiveChanged: {
            if (active) { AppModel.dragPayload = slot.payload; AppModel.dragLabel = slot.payload.label || "" }
            else AppModel.dragEnded()
        }
        onCentroidChanged: if (active) AppModel.dragScenePos = centroid.scenePosition
    }

    DropArea {
        anchors.fill: parent
        anchors.leftMargin: slot.freeLeading
        keys: ["girocrab-sidebar"]
        function update(y) {
            const half = y < height / 2 ? "above" : "below"
            const edge = AppModel.dragPayload ? slot.edgeFor(half, AppModel.dragPayload) : null
            AppModel.dropLine = edge ? { key: edge === "into" ? slot.intoKey : slot.key, edge: edge, zone: slot.key } : null
        }
        onEntered: d => update(d.y)
        onPositionChanged: d => update(d.y)
        onExited: if (AppModel.dropLine && AppModel.dropLine.zone === slot.key) AppModel.dropLine = null
        onDropped: d => {
            const line = AppModel.dropLine, p = AppModel.dragPayload
            AppModel.dropLine = null
            if (line && line.zone === slot.key && p) slot.perform(p, line.edge)
        }
    }

    // .background: "into" highlight
    Rectangle {
        visible: AppModel.dropLine !== null && AppModel.dropLine.key === slot.key && AppModel.dropLine.edge === "into"
        x: slot.inset - 4; y: -2; width: parent.width - x; height: parent.height + 4
        radius: 5
        color: Theme.withAlpha(Theme.accent, 0.18)
        border.color: Theme.accent; border.width: 1.5
        z: -1
    }
    // .overlay: insertion line with a small circle
    Row {
        visible: AppModel.dropLine !== null && AppModel.dropLine.key === slot.key && AppModel.dropLine.edge !== "into"
        x: slot.inset
        y: AppModel.dropLine && AppModel.dropLine.edge === "below" ? parent.height - 1 : -2
        Rectangle { width: 7; height: 7; radius: 3.5; color: "transparent"; border.color: Theme.secondary; border.width: 1.5; anchors.verticalCenter: parent.verticalCenter }
        Rectangle { width: slot.width - slot.inset - 7; height: 1.5; color: Theme.secondary; anchors.verticalCenter: parent.verticalCenter }
    }
}
