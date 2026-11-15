import QtQuick
import QtQuick.Controls

// Scroll bar that stays visible whenever there is something to scroll (Fusion's only
// appears while scrolling or hovering, so long lists looked unscrollable): a slim
// rounded handle in the text colour, a little wider and stronger under the mouse.
// It overlays the list edge, so hovering never shifts the layout.
ScrollBar {
    id: sb
    policy: size < 1.0 ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
    minimumSize: 0.05
    padding: 2
    background: Item {}
    contentItem: Rectangle {
        implicitWidth: sb.hovered || sb.pressed ? 8 : 5
        implicitHeight: implicitWidth
        radius: width / 2
        color: Theme.secondary
        opacity: sb.pressed ? 0.75 : sb.hovered ? 0.6 : 0.38
        Behavior on implicitWidth { NumberAnimation { duration: 110 } }
        Behavior on opacity { NumberAnimation { duration: 110 } }
    }
}
