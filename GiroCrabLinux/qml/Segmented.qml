import QtQuick
import QtQuick.Layouts

// Picker(…).pickerStyle(.segmented) in the macOS look.
Rectangle {
    id: seg
    property var options: []          // [{id, title}]
    property string current
    property int fontSize: Theme.body
    signal activated(string id)
    implicitHeight: 24
    implicitWidth: row.implicitWidth + 4
    radius: 6
    color: Theme.withAlpha(Theme.secondary, 0.12)
    // Picker("Zeitraum", …) (#571, ff91866): the picker's hidden label goes into Accessible.name
    // at the call site; each segment is a tab that says whether it is chosen and can be pressed.
    Accessible.role: Accessible.PageTabList
    RowLayout {
        id: row
        anchors.fill: parent; anchors.margins: 2
        spacing: 0
        Repeater {
            model: seg.options
            Rectangle {
                required property var modelData
                Layout.fillWidth: true; Layout.fillHeight: true
                implicitWidth: label.implicitWidth + 24
                radius: 5
                color: seg.current === modelData.id ? Theme.card : "transparent"
                border.color: seg.current === modelData.id ? Theme.border : "transparent"
                Text { id: label; anchors.centerIn: parent; text: modelData.title; font.pixelSize: seg.fontSize; color: Theme.text }
                MouseArea { anchors.fill: parent; onClicked: seg.activated(modelData.id) }
                Accessible.role: Accessible.PageTab
                Accessible.name: modelData.title
                Accessible.selected: seg.current === modelData.id
                Accessible.onPressAction: seg.activated(modelData.id)
            }
        }
    }
}
