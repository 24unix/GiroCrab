import QtQuick

// Formatting.swift › CardBackground: card with a 1px hairline border.
Rectangle {
    default property alias content: inner.data
    property int padding: 16
    color: Theme.card
    radius: 12
    border.color: Theme.border
    border.width: 1
    implicitHeight: inner.childrenRect.height + 2 * padding
    Item {
        id: inner
        anchors.fill: parent
        anchors.margins: parent.padding
    }
}
