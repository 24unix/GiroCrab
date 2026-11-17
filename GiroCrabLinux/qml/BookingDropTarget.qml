import QtQuick

// SidebarView.swift › the DropSlot of a category row with `takesBookings` (#366): bookings
// dragged from the list are assigned to this category. Only categories without sub-categories
// take them (as only leaves are assigned, like the inspector's grid). Marks only booking drags.
// Put it into a category row: BookingDropTarget { categoryID: …; enabled: !hasChildren }.
DropArea {
    id: target
    property var categoryID: null
    anchors.fill: parent
    keys: [BookingDrag.key]
    onDropped: d => { if (target.enabled && BookingDrag.dropOnCategory(target.categoryID)) d.accept() }

    // "into" highlight, as the sidebar's own drop zones draw it
    Rectangle {
        visible: target.enabled && target.containsDrag
        x: -4; y: -2; width: parent.width + 4; height: parent.height + 4
        radius: 5
        color: Theme.withAlpha(Theme.accent, 0.18)
        border.color: Theme.accent; border.width: 1.5
        z: -1
    }
}
