import QtQuick
import QtQuick.Layouts

// Section { … } header: { … } footer: { … } of a grouped Form (.formStyle(.grouped)):
// header, the rows in a rounded box, footer lines below. The defaults are the sheet
// style (import, print, loans); SettingsFormSection sets the Settings window's style.
ColumnLayout {
    id: s
    property string title
    /// Footer lines; empty strings are left out.
    property var footers: []
    /// A single footer line (shown after `footers`).
    property string footer: ""
    default property alias rows: box.data

    // style
    property alias headerFont: header.font
    property color headerColor: Theme.secondary
    /// Leading inset of header and footer lines.
    property real headerInset: 10
    /// Trailing inset of the footer lines.
    property real footerTrailingInset: 0
    property color boxColor: Theme.withAlpha(Theme.secondary, 0.06)
    property real boxRadius: 8
    /// Padding inside the box.
    property real inset: 10
    property real rowSpacing: 8

    Layout.fillWidth: true
    spacing: 5
    Text {
        id: header
        visible: s.title !== ""
        text: s.title
        Layout.leftMargin: s.headerInset
        font.pixelSize: Theme.callout; font.weight: Font.DemiBold; color: s.headerColor
    }
    Rectangle {
        Layout.fillWidth: true
        implicitHeight: box.implicitHeight + 2 * s.inset
        radius: s.boxRadius
        color: s.boxColor
        border.color: Theme.border
        ColumnLayout {
            id: box
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
            anchors.margins: s.inset
            spacing: s.rowSpacing
        }
    }
    Repeater {
        model: s.footers.concat([s.footer]).filter(x => !!x)
        Text {
            required property string modelData
            text: modelData
            Layout.fillWidth: true; Layout.leftMargin: s.headerInset; Layout.rightMargin: s.footerTrailingInset
            wrapMode: Text.WordWrap
            font.pixelSize: Theme.caption; color: Theme.secondary
        }
    }
}
