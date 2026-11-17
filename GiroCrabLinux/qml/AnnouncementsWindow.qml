import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// AnnouncementsUI.swift › AnnouncementsListView: Hilfe › Mitteilungen … – everything that
// applies to this build, including what was dismissed, so nobody has to fear having lost
// something. Window("Mitteilungen", id: "announcements"), default size 460 × 360.
ApplicationWindow {
    id: win
    Binding on palette { when: Theme.forced !== ""; value: Theme.forcedPalette }
    font.pointSize: Theme.controlPointSize   // appTextSize (#343)
    title: qsTr("Mitteilungen")
    width: 460; height: 360
    minimumWidth: 380; minimumHeight: 280
    color: Theme.canvas
    visible: Announcements.showWindow
    onClosing: Announcements.showWindow = false
    // `.task { await center.refresh() }`
    onVisibleChanged: if (visible) { Announcements.refresh(false); requestActivate(); raise() }
    Component.onCompleted: { Announcements.refresh(false); requestActivate(); raise() }

    // ContentUnavailableView("Keine Mitteilungen", systemImage: "tray", description: …)
    ColumnLayout {
        anchors.centerIn: parent
        width: parent.width - 60
        visible: Announcements.all.length === 0
        spacing: 8
        SFIcon { Layout.alignment: Qt.AlignHCenter; symbol: "tray"; size: 40; color: Theme.tertiary }
        Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("Keine Mitteilungen")
               font.pixelSize: Theme.title2; font.weight: Font.DemiBold; color: Theme.text }
        Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
               font.pixelSize: Theme.body; color: Theme.secondary
               text: Announcements.isEnabled ? qsTr("Es gibt derzeit nichts Neues vom GiroCrab-Projekt.")
                                             : qsTr("Mitteilungen sind in den Einstellungen ausgeschaltet.") }
    }

    ListView {
        anchors.fill: parent
        anchors.margins: 12
        visible: Announcements.all.length > 0
        clip: true
        spacing: 4
        model: Announcements.all
        ScrollBar.vertical: AppScrollBar {}
        delegate: ColumnLayout {
            required property var modelData
            required property int index
            width: ListView.view.width
            spacing: 6
            Rectangle { visible: index > 0; Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }
            Text { Layout.fillWidth: true; Layout.topMargin: 4; wrapMode: Text.WordWrap; text: modelData.title
                   font.pixelSize: Theme.body; font.weight: Font.DemiBold; color: Theme.text }
            TextEdit {
                Layout.fillWidth: true
                readOnly: true; selectByMouse: true; wrapMode: Text.WordWrap
                textFormat: TextEdit.MarkdownText
                text: modelData.body !== "" ? modelData.body : modelData.summary
                font.pixelSize: Theme.body; color: Theme.secondary; selectionColor: Theme.accent
                onLinkActivated: link => Qt.openUrlExternally(link)
            }
            Text {
                visible: !!modelData.link
                Layout.bottomMargin: 4
                text: qsTr("Mehr im Web")
                font.pixelSize: Theme.body; color: Theme.accent; font.underline: webMouse.containsMouse
                MouseArea { id: webMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: Qt.openUrlExternally(modelData.link) }
            }
        }
    }
}
