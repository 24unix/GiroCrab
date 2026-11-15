import QtQuick
import QtQuick.Controls

// .sheet(…) on macOS: a modal panel centred over the window, card-styled.
Dialog {
    id: sheet
    default property alias body: content.data
    property int sheetWidth: 440
    /// Height left for the body inside the window (small windows such as Settings):
    /// sheets with a fixed-height list or scroll area clamp it to this.
    readonly property real maxBodyHeight: (Overlay.overlay ? Overlay.overlay.height : 800) - 40 - topPadding - bottomPadding
    modal: true
    // Always sized and centred against the window's overlay, also when the sheet is
    // created inside a Loader (whose own size is 0) – otherwise the background vanishes.
    parent: Overlay.overlay
    anchors.centerIn: Overlay.overlay
    closePolicy: Popup.CloseOnEscape
    padding: 24
    width: Math.min(sheetWidth, parent ? parent.width - 40 : sheetWidth)
    height: Math.min(implicitHeight, parent ? parent.height - 40 : implicitHeight)
    background: Rectangle { color: Theme.card; radius: 12; border.color: Theme.border }
    header: null
    footer: null
    contentItem: Item {
        implicitWidth: content.childrenRect.width
        implicitHeight: content.childrenRect.height
        Item { id: content; anchors.fill: parent }
    }
}
