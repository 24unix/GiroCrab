import QtQuick
import QtQuick.Controls
import QtQuick.Controls.impl
import QtQuick.Layouts

// Menu entry laid out like a macOS menu item, in fixed columns:
//   [✓ check column] [icon column] Title ……………… Shortcut  [› submenu]
// The check and icon columns are reserved for every entry of a menu as soon as one
// entry needs them (AppMenu.anyCheckable / anyIcon), so all titles start on one line.
// Title and shortcut sit in one RowLayout and can never overlap: if the menu is too
// narrow the title is elided. Used as AppMenu's delegate and directly in context menus.
MenuItem {
    id: control

    readonly property bool reserveCheck: menu && menu.anyCheckable !== undefined ? menu.anyCheckable : checkable
    readonly property bool reserveIcon: menu && menu.anyIcon !== undefined ? menu.anyIcon
                                                                           : (icon.name !== "" || icon.source.toString() !== "")
    readonly property bool lit: (highlighted || down) && enabled
    readonly property color textColor: lit ? "#FFFFFF" : Theme.text

    // GiroCrab look: rounded highlight in the accent colour, a little air around the text.
    implicitHeight: Math.max(28, implicitContentHeight + topPadding + bottomPadding)
    topPadding: 4; bottomPadding: 4; leftPadding: 8; rightPadding: 10
    background: Rectangle {
        implicitWidth: 200
        radius: 5
        color: control.lit ? Theme.accent : "transparent"
    }
    arrow: Text {
        x: control.width - width - control.rightPadding
        y: (control.height - height) / 2
        visible: control.subMenu
        text: "›"
        font.pixelSize: control.font.pixelSize + 4
        color: control.textColor
        opacity: control.enabled ? 0.8 : 0.4
    }

    // Resolves strings ("Ctrl+N") and StandardKey values to the platform text.
    Shortcut {
        id: keySequence
        enabled: false
        sequence: control.action && control.action.shortcut !== undefined ? control.action.shortcut : ""
    }
    /// Arrow keys as symbols instead of Qt's German words ("Herunter", "Hoch" …).
    readonly property string shortcutText: keySequence.nativeText
        .replace(/Herunter|Runter|Down/g, "↓").replace(/Hoch|Up/g, "↑")
        .replace(/Links|Left/g, "←").replace(/Rechts|Right/g, "→")

    indicator: Item {}   // drawn as ✓ in the check column below

    contentItem: RowLayout {
        spacing: 0
        readonly property real arrowPadding: control.subMenu && control.arrow ? control.arrow.width + control.spacing : 0

        Text {   // check column
            visible: control.reserveCheck
            Layout.preferredWidth: 18
            text: control.checkable && control.checked ? "✓" : ""
            font: control.font
            color: control.textColor
            opacity: control.enabled ? 1 : 0.4
        }
        Item {   // icon column
            visible: control.reserveIcon
            Layout.preferredWidth: 22
            implicitHeight: 16
            IconImage {
                anchors.verticalCenter: parent.verticalCenter
                width: 16; height: 16
                name: control.icon.name
                source: control.icon.source
                color: control.icon.color
                opacity: control.enabled ? 1 : 0.4
            }
        }
        Text {   // title, shown literally: "&" is always "&" (menu entries never use mnemonics),
                 // so category, account and group names with "&" from the data display right;
                 // "&&" in fixed texts (escaped for stock controls) shows as one "&" too
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            text: control.text.replace(/&&/g, "&")
            elide: Text.ElideRight
            font: control.font
            color: control.textColor
            opacity: control.enabled ? 1 : 0.4
        }
        Text {   // shortcut
            visible: text !== ""
            Layout.leftMargin: 28
            text: control.shortcutText
            font: control.font
            color: control.textColor
            opacity: control.enabled ? 0.6 : 0.3
        }
        Item { Layout.preferredWidth: parent.arrowPadding; visible: parent.arrowPadding > 0 }
    }
}
