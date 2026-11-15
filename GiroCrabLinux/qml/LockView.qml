import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// RootView.swift › LockView: the vault is locked (or failed to open).
// Touch ID / Face ID become the keyring prompt (KWallet / GNOME Schlüsselbund).
Rectangle {
    id: lock
    property string error: ""
    color: Theme.canvas
    /// The unlock has been waiting for a while: most likely a keyring prompt the
    /// user hasn't noticed (behind the window, other screen).
    property bool waitingLong: false
    readonly property bool unlocking: AppModel.vaultState === "unlocking"
    onUnlockingChanged: { waitingLong = false; if (unlocking) waitTimer.restart() }
    Timer { id: waitTimer; interval: 5000; onTriggered: lock.waitingLong = lock.unlocking }

    ColumnLayout {
        anchors.centerIn: parent
        width: Math.min(parent.width - 80, 520)
        spacing: 18
        Image {
            Layout.alignment: Qt.AlignHCenter
            source: "qrc:/qt/qml/GiroCrab/assets/app-icon.png"
            sourceSize.width: 120; sourceSize.height: 120
            scale: AppModel.unlockCelebrating ? 1.08 : 1
            Behavior on scale { NumberAnimation { duration: 160 } }
            opacity: lock.error !== "" ? 0.6 : 1
        }
        Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("GiroCrab ist gesperrt"); font.pixelSize: Theme.title + 2; font.weight: Font.Bold; color: Theme.text }
        Text {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
            text: qsTr("Ihre Buchungen liegen in einem verschlüsselten Tresor.\nDer Schlüssel verlässt nie den Schlüsselbund dieses Geräts.")
            font.pixelSize: Theme.body + 1; color: Theme.secondary
        }
        Button {
            Layout.alignment: Qt.AlignHCenter
            text: qsTr("Mit Schlüsselbund entsperren")
            icon.name: "object-unlocked"
            highlighted: true
            enabled: !lock.unlocking
            padding: 10; leftPadding: 18; rightPadding: 18
            onClicked: AppModel.unlock()
        }
        ColumnLayout {
            visible: lock.unlocking
            Layout.alignment: Qt.AlignHCenter
            spacing: 10
            Spinner { Layout.alignment: Qt.AlignHCenter; size: 36 }
            Text {
                Layout.alignment: Qt.AlignHCenter
                text: AppModel.unlockPhase === "loading" ? qsTr("Tresor wird geöffnet – Buchungen werden geladen …")
                                                         : qsTr("Warte auf den Schlüsselbund …")
                color: Theme.text; font.pixelSize: Theme.body + 1; font.weight: Font.Medium
            }
            Text {
                visible: AppModel.unlockPhase === "loading"
                Layout.alignment: Qt.AlignHCenter
                text: qsTr("Bei vielen Buchungen kann das einen Moment dauern.")
                color: Theme.secondary; font.pixelSize: Theme.callout
            }
        }
        Text {
            visible: lock.unlocking && lock.waitingLong && AppModel.unlockPhase === "keyring"
            Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
            text: qsTr("Bitte bestätigen Sie die Abfrage des Schlüsselbunds (KWallet oder GNOME Schlüsselbund). Sie kann hinter diesem Fenster oder auf einem anderen Bildschirm liegen.")
            font.pixelSize: Theme.callout + 1; color: Theme.warning
        }
        Text {
            visible: lock.error !== ""
            Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
            text: lock.error; font.pixelSize: Theme.callout + 1; color: "red"
        }
        Button {
            visible: AppModel.lockPreview && !AppModel.vaultMayHoldRealData() && !lock.unlocking
            Layout.alignment: Qt.AlignHCenter
            text: qsTr("Zurück zur Demo"); flat: true
            onClicked: AppModel.endLockPreview()
        }
    }
}
