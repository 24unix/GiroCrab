import QtQuick
import QtQuick.Controls

// PlanningUI.swift › CardChevron (GitHub #603): folds a card above the booking list to its
// title row. chevron.up while open, chevron.down while folded.
Item {
    id: chevron
    property bool collapsed: false
    /// Overrides „Einblenden“ / „Ausblenden“ (the stream header names what it does).
    property string customTitle: ""
    readonly property string title: customTitle !== "" ? customTitle : collapsed ? qsTr("Einblenden") : qsTr("Ausblenden")
    signal toggled()
    implicitWidth: icon.width + 8; implicitHeight: icon.height + 8
    SFIcon { id: icon; anchors.centerIn: parent; symbol: "chevron.down"; size: 10; color: Theme.secondary
             rotation: chevron.collapsed ? 0 : 180 }
    MouseArea { id: area; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: chevron.toggled() }
    ToolTip.visible: area.containsMouse; ToolTip.delay: 600; ToolTip.text: title
    // a Button on the Mac: Tab reaches it, Space / Return toggles it
    activeFocusOnTab: true
    Keys.onSpacePressed: chevron.toggled()
    Keys.onReturnPressed: chevron.toggled()
    Keys.onEnterPressed: chevron.toggled()
    Rectangle {
        visible: chevron.activeFocus
        anchors.fill: parent
        radius: 4; color: "transparent"; border.width: 2; border.color: Theme.accent
    }
    Accessible.role: Accessible.Button; Accessible.name: title
    Accessible.onPressAction: chevron.toggled()
}
