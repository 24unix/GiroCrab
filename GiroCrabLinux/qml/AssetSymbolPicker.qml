import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// TangibleAssetsUI.swift › AssetSymbolPicker: grid of icons by topic (a popover under the
// editor's icon button), sized to show every icon without scrolling.
Popup {
    id: picker
    // ReportDialogs.swift › capturablePopover (#384): drawn into the bug report picture
    onOpened: ReportDialogs.track(picker)
    onClosed: ReportDialogs.untrack(picker)
    Component.onDestruction: ReportDialogs.untrack(picker)
    /// The icon the item shows now (its type default while none is chosen).
    property string current
    signal picked(string symbol)
    padding: 14
    background: Rectangle { color: Theme.card; radius: 10; border.color: Theme.border }
    contentItem: ColumnLayout {
        spacing: 12
        Repeater {
            model: AssetSymbols.groups
            ColumnLayout {
                required property var modelData
                spacing: 6
                Text { text: modelData.title; font.pixelSize: Theme.caption; font.weight: Font.DemiBold; color: Theme.secondary }
                GridLayout {
                    columns: 8; columnSpacing: 8; rowSpacing: 8
                    Repeater {
                        model: modelData.items
                        Rectangle {
                            id: tile
                            required property var modelData
                            readonly property bool selected: picker.current === modelData.symbol
                            implicitWidth: 38; implicitHeight: 38; radius: 8
                            color: selected ? Theme.withAlpha(Theme.accent, 0.18) : tileArea.containsMouse ? Theme.withAlpha(Theme.secondary, 0.08) : "transparent"
                            border.color: selected ? Theme.accent : Theme.withAlpha(Theme.tertiary, 0.3)
                            AssetSymbolImage { anchors.centerIn: parent; symbol: tile.modelData.symbol; size: 18
                                               color: tile.selected ? Theme.accent : Theme.secondary }
                            MouseArea { id: tileArea; anchors.fill: parent; hoverEnabled: true
                                        onClicked: { picker.picked(tile.modelData.symbol); picker.close() } }
                            ToolTip.visible: tileArea.containsMouse; ToolTip.delay: 500; ToolTip.text: modelData.name
                            Accessible.role: Accessible.Button; Accessible.name: modelData.name
                        }
                    }
                }
            }
        }
    }
}
