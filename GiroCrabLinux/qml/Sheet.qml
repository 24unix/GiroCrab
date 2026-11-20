import QtQuick
import QtQuick.Controls

// .sheet(…) on macOS: a modal panel centred over the window, card-styled.
// ReportDialogs.swift › capturableSheet (#384): while open it is drawn into the bug report
// screenshot over its window (ReportDialogs.qml); mark personal data in it with `Sensitive {}`.
Dialog {
    id: sheet
    default property alias body: content.data
    /// false: an alert or confirmation dialog (`.alert` / `.confirmationDialog` on the Mac,
    /// which the system draws): never in the bug report picture, which then says so.
    property bool reportCapturable: true
    onOpened: if (reportCapturable) ReportDialogs.track(sheet)
    onClosed: ReportDialogs.untrack(sheet)
    Component.onDestruction: ReportDialogs.untrack(sheet)
    property int sheetWidth: 440
    /// Height left for the body inside the window (small windows such as Settings):
    /// sheets with a fixed-height list or scroll area clamp it to this.
    readonly property real maxBodyHeight: (Overlay.overlay ? Overlay.overlay.height : 800) - 40 - topPadding - bottomPadding
    modal: true
    // Always sized and centred against the window's overlay, also when the sheet is
    // created inside a Loader (whose own size is 0) – otherwise the background vanishes.
    parent: Overlay.overlay
    // A sheet of the main window opened from the settings window (e.g. „Neu verbinden“ →
    // consent page): bring its window to the front, or it waits hidden behind the settings.
    onAboutToShow: {
        const w = parent && parent.Window ? parent.Window.window : null
        if (w) { w.raise(); w.requestActivate() }
    }
    anchors.centerIn: Overlay.overlay
    closePolicy: Popup.CloseOnEscape
    padding: 24
    // macFrame: fixed sheet widths grow with the text size (#343), like the text in them
    width: Math.min(sheetWidth * Theme.textScale, parent ? parent.width - 40 : sheetWidth * Theme.textScale)
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
