import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Borderless toolbar/inline button with an SF Symbol (Button { Label(…, systemImage:) }
// .buttonStyle(.borderless)); the symbol is drawn like every other icon (SFIcon).
ToolButton {
    id: b
    property string symbol
    property int symbolSize: 16
    property color tint: enabled ? Theme.secondary : Theme.withAlpha(Theme.secondary, 0.4)
    /// Label colour (role: .destructive → Theme.negative).
    property color textColor: Theme.text
    implicitWidth: Math.max(28, content.implicitWidth + 12)
    implicitHeight: 26
    contentItem: Item {
        implicitWidth: content.implicitWidth; implicitHeight: content.implicitHeight
        RowLayout {
            id: content
            anchors.centerIn: parent
            spacing: 5
            SFIcon { visible: b.symbol !== ""; symbol: b.symbol; size: b.symbolSize; color: b.checked ? Theme.accent : b.tint }
            Text { visible: b.text !== ""; text: b.text; font.pixelSize: b.font.pixelSize > 0 ? b.font.pixelSize : Theme.body; color: b.enabled ? b.textColor : Theme.tertiary }
        }
    }
    // Label("…", systemImage:).labelStyle(.iconOnly) + .help (#571, ff91866): a symbol-only button
    // is read by its tooltip text instead of nothing; an explicit Accessible.name still wins.
    Accessible.name: text !== "" ? text : ToolTip.text
    ToolTip.visible: hovered && ToolTip.text !== ""
    ToolTip.delay: 600
}
