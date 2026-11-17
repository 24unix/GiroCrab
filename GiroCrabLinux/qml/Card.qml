import QtQuick

// Formatting.swift › CardBackground: card with a 1px hairline border.
// `verticalPadding` overrides the top/bottom inset only (collapsed header cards, GitHub #603).
Rectangle {
    default property alias content: inner.data
    property int padding: 16
    property int verticalPadding: padding
    color: Theme.card
    radius: 12
    border.color: Theme.border
    border.width: 1
    implicitHeight: inner.childrenRect.height + 2 * verticalPadding
    Item {
        id: inner
        anchors.fill: parent
        anchors.leftMargin: parent.padding; anchors.rightMargin: parent.padding
        anchors.topMargin: parent.verticalPadding; anchors.bottomMargin: parent.verticalPadding
    }
}
