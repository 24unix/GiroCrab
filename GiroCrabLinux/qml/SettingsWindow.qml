import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// SettingsView.swift: the macOS Settings window with its tabs Allgemein, Banken, Sicherheit.
// Dropped on Linux: Dokumente (document folder), Updates (Sparkle).
Window {
    id: win
    // `--dark` / `--light`: the controls follow the forced appearance (Theme.forcedPalette)
    Binding on palette { when: Theme.forced !== ""; value: Theme.forcedPalette }
    title: qsTr("Einstellungen")
    // HIG: each tab has its own height and the window follows it.
    readonly property var tabs: [
        { id: "general", title: qsTr("Allgemein"), symbol: "gearshape", height: 420 },
        { id: "banks", title: qsTr("Banken"), symbol: "building.columns", height: 600 },
        { id: "security", title: qsTr("Sicherheit"), symbol: "lock.shield", height: 780 }]
    readonly property int tabIndex: Math.max(0, tabs.findIndex(t => t.id === AppModel.settingsTab))
    width: 680
    height: tabs[tabIndex].height
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
            SecuritySettings {}
        }
    }
}
