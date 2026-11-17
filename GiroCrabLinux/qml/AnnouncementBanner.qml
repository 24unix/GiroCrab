import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// AnnouncementsUI.swift › AnnouncementBanner: quiet project news above the booking list.
// * Banner, not alert: nothing interrupts, nothing blocks the window.
// * "important" differs only by the filled accent-coloured symbol – no red, red is
//   reserved for the security lock.
// * Always dismissible with a labelled close button; "Mehr erfahren" opens a sheet
//   with the full text (AnnouncementSheet), never the browser unasked.
// * Not shown while a security lock is visible: one message at a time.
Item {
    id: banner
    readonly property var announcement: Announcements.banner
    // One message at a time: the security lock always wins.
    readonly property bool shown: announcement !== null && !AppModel.bankingPolicy.gate
    visible: shown
    implicitHeight: shown ? box.implicitHeight + 16 : 0

    // `.task { await center.refresh() }`
    Component.onCompleted: Announcements.refresh(false)

    readonly property bool hasMore: shown && (announcement.body !== "" || !!announcement.link)

    Rectangle {
        id: box
        // .padding(.horizontal, 20).padding(.vertical, 8)
        x: 20; y: 8
        width: parent.width - 40
        implicitHeight: row.implicitHeight + 24
        radius: 12
        color: Theme.card
        border.color: Theme.border
        RowLayout {
            id: row
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 12
            spacing: 10
            SFIcon {
                Layout.alignment: Qt.AlignTop
                Layout.topMargin: 1
                // info.circle(.fill): Breeze has one info symbol, "important" differs by its accent colour
                symbol: "info.circle"
                size: Theme.title3 + 2
                color: banner.shown && banner.announcement.severity === "important" ? Theme.accent : Theme.secondary
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 4
                Text { Layout.fillWidth: true; wrapMode: Text.WordWrap
                       text: banner.shown ? banner.announcement.title : ""
                       font.pixelSize: Theme.body; font.weight: Font.DemiBold; color: Theme.text }
                Text { Layout.fillWidth: true; wrapMode: Text.WordWrap
                       visible: banner.shown && banner.announcement.summary !== ""
                       text: banner.shown ? banner.announcement.summary : ""
                       textFormat: Text.MarkdownText
                       font.pixelSize: Theme.callout; color: Theme.secondary; linkColor: Theme.accent
                       onLinkActivated: link => Qt.openUrlExternally(link)
                       HoverHandler { enabled: parent.hoveredLink !== ""; cursorShape: Qt.PointingHandCursor } }
                // Button("Mehr erfahren").buttonStyle(.link)
                Text {
                    visible: banner.hasMore
                    Layout.topMargin: 2
                    text: qsTr("Mehr erfahren")
                    font.pixelSize: Theme.callout; color: Theme.accent
                    font.underline: moreMouse.containsMouse
                    Accessible.role: Accessible.Button
                    Accessible.name: text
                    Accessible.onPressAction: sheet.present(banner.announcement)
                    MouseArea { id: moreMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: sheet.present(banner.announcement) }
                }
            }
            IconButton {
                Layout.alignment: Qt.AlignTop
                symbol: "xmark"; symbolSize: 11
                Accessible.name: qsTr("Mitteilung ausblenden")
                ToolTip.text: qsTr("Mitteilung ausblenden")
                onClicked: Announcements.dismiss(banner.announcement)
            }
        }
    }

    // AnnouncementsUI.swift › AnnouncementSheet
    Sheet {
        id: sheet
        property var announcement: null
        function present(a) { announcement = a; open() }
        sheetWidth: 460
        ColumnLayout {
            width: sheet.availableWidth
            spacing: 16
            Text { Layout.fillWidth: true; wrapMode: Text.WordWrap
                   text: sheet.announcement ? sheet.announcement.title : ""
                   font.pixelSize: Theme.title2; font.weight: Font.DemiBold; color: Theme.text }
            ScrollView {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(bodyText.implicitHeight + 4, Math.max(120, sheet.maxBodyHeight - 120))
                ScrollBar.vertical: ScrollViewBar {}
                contentWidth: availableWidth
                TextEdit {
                    id: bodyText
                    width: parent.width
                    readOnly: true; selectByMouse: true
                    wrapMode: Text.WordWrap
                    textFormat: TextEdit.MarkdownText
                    text: !sheet.announcement ? ""
                          : (sheet.announcement.body !== "" ? sheet.announcement.body : sheet.announcement.summary)
                    font.pixelSize: Theme.body; color: Theme.text
                    selectionColor: Theme.accent
                    onLinkActivated: link => Qt.openUrlExternally(link)
                    HoverHandler { enabled: bodyText.hoveredLink !== ""; cursorShape: Qt.PointingHandCursor }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Button { visible: !!(sheet.announcement && sheet.announcement.link); text: qsTr("Mehr im Web")
                         onClicked: Qt.openUrlExternally(sheet.announcement.link) }
                Item { Layout.fillWidth: true }
                Button { text: qsTr("OK"); highlighted: true; onClicked: sheet.close() }
            }
        }
        // OK is the default button
        Shortcut { sequences: ["Return", "Enter"]; enabled: sheet.visible; onActivated: sheet.close() }
    }
}
