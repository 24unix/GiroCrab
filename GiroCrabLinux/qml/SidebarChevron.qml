import QtQuick

// SidebarView.swift › DisclosureChevron: the disclosure arrow of every collapsible sidebar
// header – `chevron.right` when closed, turned down when open. One 14 px column, so the
// icons of all headers and accounts share one vertical axis.
Item {
    property bool open: true
    property string accessibleName
    signal toggled()
    implicitWidth: SidebarModel.slot; implicitHeight: 18
    Accessible.role: Accessible.Button
    Accessible.name: accessibleName
    Accessible.description: open ? qsTr("Ausgeklappt") : qsTr("Eingeklappt")
    Accessible.onPressAction: toggled()
    SFIcon { anchors.centerIn: parent; symbol: "chevron.right"; size: 10; color: Theme.secondary
             rotation: parent.open ? 90 : 0
             Behavior on rotation { NumberAnimation { duration: 150 } } }
    MouseArea { anchors.fill: parent; anchors.margins: -4; onClicked: parent.toggled() }
}
