import QtQuick

// BookingListView.swift › DayCardSegment: one slice of a rounded card that is split into a
// header and rows (the day cards of the booking stream, the month cards of „Geplant“, the
// mandate card of „Lastschriften“). Only the top slice is rounded at the top, only the
// bottom slice at the bottom; slices below the top draw no top line (the rows draw their
// own hairlines). Put it behind the slice's content.
Item {
    id: seg
    property bool isTop: false
    property bool isBottom: false
    readonly property real r: Math.min(12, height / 2)

    Rectangle { anchors.fill: parent; radius: seg.r; color: Theme.card; border.color: Theme.border }
    Rectangle {
        visible: !seg.isTop
        anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
        height: seg.isBottom ? parent.height - seg.r : parent.height / 2
        color: Theme.card
        Rectangle { anchors.left: parent.left; width: 1; height: parent.height; color: Theme.border }
        Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.border }
    }
    Rectangle {
        visible: !seg.isBottom
        anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right
        height: seg.isTop ? parent.height - seg.r : parent.height / 2
        color: Theme.card
        Rectangle { anchors.left: parent.left; width: 1; height: parent.height; color: Theme.border }
        Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.border }
    }
}
