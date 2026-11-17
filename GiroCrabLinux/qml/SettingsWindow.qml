import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// SettingsView.swift: the macOS Settings window with its tabs Allgemein, Banken, Sicherheit.
// Dropped on Linux: Dokumente (document folder), Updates (Sparkle).
ApplicationWindow {
    id: win
    // `--dark` / `--light`: the controls follow the forced appearance (Theme.forcedPalette)
    Binding on palette { when: Theme.forced !== ""; value: Theme.forcedPalette }
    // appTextSize (#343): an ApplicationWindow so the controls inherit the scaled font
    font.pointSize: Theme.controlPointSize
    title: qsTr("Einstellungen")
    // an independent window like the Mac's Settings, not a dialog pinned above the main
    // window: bank dialogs (PIN, TAN, consent) of the main window must be able to come to front
    transientParent: null
    // HIG: each tab has its own height and the window follows it.
    readonly property var tabs: [
        // SettingsView.swift › settingsPane(height:): "Allgemein" 600 since #343/#388 (it scrolls)
        { id: "general", title: qsTr("Allgemein"), symbol: "gearshape", height: 600 },
        { id: "banks", title: qsTr("Banken"), symbol: "building.columns", height: 600 },
        { id: "security", title: qsTr("Sicherheit"), symbol: "lock.shield", height: 780 }]
    readonly property int tabIndex: Math.max(0, tabs.findIndex(t => t.id === AppModel.settingsTab))
    width: 680 * Theme.textScale   // SettingsPaneFrame: 680 × textScale
    // never taller than the screen (small laptop displays)
    height: Math.min(tabs[tabIndex].height, Screen.desktopAvailableHeight - 60)
    minimumWidth: 560; minimumHeight: 360
    color: Theme.canvas
    visible: AppModel.showSettings
    onClosing: AppModel.showSettings = false
    onVisibleChanged: if (visible) { requestActivate(); raise() }

    Shortcut { sequences: [StandardKey.Close]; onActivated: win.close() }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        // Toolbar-style tab picker
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 62
            color: Theme.sidebar
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }
            RowLayout {
                anchors.centerIn: parent
                spacing: 4
                Repeater {
                    model: win.tabs
                    Rectangle {
                        id: tab
                        required property var modelData
                        required property int index
                        readonly property bool current: win.tabIndex === index
                        implicitWidth: Math.max(76, col.implicitWidth + 20); implicitHeight: 50
                        radius: 7
                        color: current ? Theme.withAlpha(Theme.secondary, 0.14) : "transparent"
                        ColumnLayout {
                            id: col
                            anchors.centerIn: parent
                            spacing: 3
                            SFIcon { Layout.alignment: Qt.AlignHCenter; symbol: tab.modelData.symbol; size: 20; color: tab.current ? Theme.accent : Theme.secondary }
                            Text { Layout.alignment: Qt.AlignHCenter; text: tab.modelData.title; font.pixelSize: Theme.callout; color: tab.current ? Theme.accent : Theme.text }
                        }
                        MouseArea { anchors.fill: parent; onClicked: AppModel.settingsTab = tab.modelData.id }
                    }
                }
            }
        }
        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: win.tabIndex
            GeneralSettings {}
            BankConnectionsSettings { enabled: AppModel.isUnlocked }
            SecuritySettings { id: security }
        }
        // AppVersion.swift › AppVersionFooter: a subtle line under every pane. Linux shows the
        // core version it was built on (the same number as „Kern-Version“ in Sicherheit), plus
        // the app version only when it differs – no build number, no TestFlight pin.
        TextEdit {
            Layout.fillWidth: true
            Layout.topMargin: 6; Layout.bottomMargin: 6
            horizontalAlignment: TextEdit.AlignHCenter
            readOnly: true; selectByMouse: true
            text: "GiroCrab " + security.versionText
            font.pixelSize: Theme.caption2; color: Theme.tertiary
        }
    }
}
