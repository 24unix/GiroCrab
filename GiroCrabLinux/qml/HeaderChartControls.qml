import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// HeaderChartControls.swift (#634): the row below the header chart. Hidden, line, bars or pie
// in one segmented group, then the bar width („Balken je“). „Ausgeblendet“ folds only the
// chart (the row, balance, KPIs and filters stay) and keeps the chosen type for when the chart
// is shown again. Same prefs as the right-click menu and Einstellungen (BalanceChartPrefs).
RowLayout {
    id: controls
    /// BarUnitMenu: the units to offer ([] = no menu), the current one and what "auto" stands for.
    property var units: []
    property string unit: ""
    property string resolved: ""
    signal unitChosen(string id)
    spacing: 8

    readonly property string choice: BalanceChartPrefs.collapsed ? "hidden" : BalanceChartPrefs.style
    readonly property var choices: [{ id: "hidden", title: qsTr("Ausgeblendet"), symbol: "eye.slash" }].concat(BalanceChartPrefs.styles)
    function choose(id) {
        if (id === "hidden") { BalanceChartPrefs.setCollapsed(true); return }
        BalanceChartPrefs.setStyle(id)
        BalanceChartPrefs.setCollapsed(false)
    }

    // Picker("Diagramm") .segmented, .controlSize(.small), icons only
    Rectangle {
        id: seg
        implicitHeight: 20
        implicitWidth: segRow.implicitWidth + 4
        radius: 5
        color: Theme.withAlpha(Theme.secondary, 0.12)
        // .help("Diagrammart") on the picker; each segment names its type (.help(s.title))
        Accessible.role: Accessible.PageTabList; Accessible.name: qsTr("Diagramm"); Accessible.description: qsTr("Diagrammart")
        Row {
            id: segRow
            anchors.centerIn: parent
            Repeater {
                model: controls.choices
                Rectangle {
                    id: segment
                    required property var modelData
                    readonly property bool selected: controls.choice === modelData.id
                    width: 30; height: 16
                    radius: 4
                    color: selected ? Theme.card : "transparent"
                    border.color: selected ? Theme.border : "transparent"
                    SFIcon { anchors.centerIn: parent; symbol: segment.modelData.symbol; size: 12; color: segment.selected ? Theme.text : Theme.secondary }
                    MouseArea { id: segArea; anchors.fill: parent; hoverEnabled: true; onClicked: controls.choose(segment.modelData.id) }
                    ToolTip.visible: segArea.containsMouse; ToolTip.delay: 600; ToolTip.text: modelData.title
                    Accessible.role: Accessible.PageTab; Accessible.name: modelData.title; Accessible.selected: selected
                    Accessible.onPressAction: controls.choose(modelData.id)
                }
            }
        }
    }

    // BarUnitMenu: "Monate ⌄" / "Auto: Monate ⌄" in caption2, opens „Balken je“
    Item {
        id: unitMenu
        visible: !BalanceChartPrefs.collapsed && controls.units.length > 0
        readonly property string label: controls.resolved !== "" ? qsTr("Auto: %1").arg(BalanceChartPrefs.unitTitle(controls.resolved))
                                                                   : BalanceChartPrefs.unitTitle(controls.unit)
        implicitWidth: unitRow.implicitWidth; implicitHeight: 20
        RowLayout {
            id: unitRow
            anchors.verticalCenter: parent.verticalCenter
            spacing: 3
            Text { text: unitMenu.label; font.pixelSize: Theme.caption2; color: Theme.secondary }
            SFIcon { symbol: "chevron.down"; size: 8; color: Theme.secondary }
        }
        MouseArea { id: unitArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: barMenu.popup() }
        ToolTip.visible: unitArea.containsMouse && !barMenu.visible; ToolTip.delay: 600; ToolTip.text: qsTr("Balken je")
        Accessible.role: Accessible.ButtonMenu; Accessible.name: qsTr("Balken je"); Accessible.description: label
        AppMenu {
            id: barMenu
            Repeater {
                model: controls.units
                AppMenuItem { required property var modelData; text: modelData.title; checkable: true
                              checked: controls.unit === modelData.id
                              onTriggered: { checked = Qt.binding(() => controls.unit === modelData.id); controls.unitChosen(modelData.id) } }
            }
        }
    }
    Item { Layout.fillWidth: true }
}
