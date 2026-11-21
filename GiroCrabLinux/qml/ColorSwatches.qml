import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs

// NewCategoryDialog.swift › ColorSwatches (+ the "Eigene Farbe" colour well):
// colour circles with a ring around the chosen one. The palette is the core's
// `account_color_palette` (IconColorPopover: plus Gelb, Braun, Schiefer), plus the current
// colour first if it is in neither row.
Flow {
    id: sw
    property string selection: ""
    property bool showCustom: true
    /// IconColorPopover of an account or group: "Standardfarbe" / "Keine Farbe" (chosen(""))
    property string noneTip: ""
    signal chosen(string hex)
    spacing: 6
    readonly property string current: selection.toUpperCase()
    /// The colours offered: the core palette (category dialog) or ColorChoices.swatches (popover).
    property var swatches: AppModel.colorPalette
    /// Colours shown in another row (IconColorPopover's „Eigene Farben“): the current one is marked there.
    property var elsewhere: []
    readonly property var colors: current === "" || swatches.indexOf(current) >= 0 || elsewhere.indexOf(current) >= 0
                                  ? swatches : [current].concat(swatches)
    Repeater {
        model: sw.colors
        Rectangle {
            id: dot
            required property string modelData
            width: 24; height: 24; radius: 12
            color: "transparent"
            border.width: 1.5
            border.color: dot.modelData === sw.current ? Theme.withAlpha(Theme.text, 0.6) : "transparent"
            Rectangle { anchors.centerIn: parent; width: 18; height: 18; radius: 9; color: Theme.readable(dot.modelData) }
            HoverHandler { id: hh }
            ToolTip.visible: hh.hovered
            ToolTip.delay: 600
            ToolTip.text: AppModel.colorNames[dot.modelData] || dot.modelData
            TapHandler { onTapped: sw.chosen(dot.modelData) }
        }
    }
    Item {
        visible: sw.noneTip !== ""
        width: 24; height: 24
        SFIcon { anchors.centerIn: parent; symbol: "arrow.uturn.backward.circle"; size: 20; color: Theme.secondary }
        HoverHandler { id: nh }
        ToolTip.visible: nh.hovered
        ToolTip.delay: 600
        ToolTip.text: sw.noneTip
        TapHandler { onTapped: sw.chosen("") }
        // IconColorPopover: .accessibilityLabel(account != nil ? "Standardfarbe" : "Keine Farbe") (#571)
        Accessible.role: Accessible.Button
        Accessible.name: sw.noneTip
        Accessible.onPressAction: sw.chosen("")
    }
    // any other colour: the system colour dialog
    Rectangle {
        visible: sw.showCustom
        width: 24; height: 24; radius: 12
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0; color: "#EF4444" }
            GradientStop { position: 0.33; color: "#22C55E" }
            GradientStop { position: 0.66; color: "#3B82F6" }
            GradientStop { position: 1; color: "#D946EF" }
        }
        HoverHandler { id: ch }
        ToolTip.visible: ch.hovered
        ToolTip.delay: 600
        ToolTip.text: qsTr("Eigene Farbe")
        TapHandler { onTapped: { colorDialog.selectedColor = sw.current !== "" ? sw.current : Theme.accent; colorDialog.open() } }
    }
    ColorDialog {
        id: colorDialog
        title: qsTr("Eigene Farbe")
        onAccepted: {
            const c = selectedColor
            const h = x => ("0" + Math.round(x * 255).toString(16)).slice(-2)
            sw.chosen(("#" + h(c.r) + h(c.g) + h(c.b)).toUpperCase())
        }
    }
}
