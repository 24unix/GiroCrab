import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// LanguagePreference.swift › LanguagePromptView: shown before the vault opens, only when the
// system language is not one the app speaks (the app would otherwise silently fall back to
// German). Main.qml starts the vault after `done`.
Rectangle {
    id: prompt
    signal done()
    color: Theme.canvas
    // English is the more likely fallback for someone whose system is in neither language.
    property string selection: "en"
    readonly property string running: (AppModel.run(() => AppModel.core("language_state")) || { running: "de" }).running
    readonly property bool needsRestart: selection !== running
    /// AppLanguage.nativeName: language names in their own language.
    function nativeName(code) { return ({ de: "Deutsch", en: "English" })[code] || code }

    function confirm() {
        AppModel.run(() => AppModel.core("set_language_choice", { choice: prompt.selection }))
        if (needsRestart) {
            AppModel.run(() => AppModel.core("request_relaunch"))
            Qt.quit()
        } else {
            done()
        }
    }

    focus: true
    Keys.onReturnPressed: confirm()
    Keys.onEnterPressed: confirm()

    ColumnLayout {
        anchors.centerIn: parent
        width: Math.min(420, prompt.width - 64)
        spacing: 18
        SFIcon { Layout.alignment: Qt.AlignHCenter; symbol: "globe"; size: 52; color: Theme.accent }
        Text {
            Layout.alignment: Qt.AlignHCenter
            text: qsTr("Sprache wählen")
            font.pixelSize: Theme.title; font.weight: Font.Bold; color: Theme.text
        }
        Text {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
            text: qsTr("GiroCrab ist in Ihrer Systemsprache noch nicht verfügbar. In welcher Sprache soll GiroCrab angezeigt werden?")
            font.pixelSize: Theme.body; color: Theme.secondary
        }
        ColumnLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: 2
            Repeater {
                model: ["de", "en"]
                RadioButton {
                    required property string modelData
                    text: prompt.nativeName(modelData)
                    checked: prompt.selection === modelData
                    onClicked: prompt.selection = modelData
                }
            }
        }
        Text {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
            text: prompt.needsRestart
                  ? qsTr("GiroCrab startet dazu kurz neu. Sie können die Sprache später in den Einstellungen ändern.")
                  : qsTr("Sie können die Sprache später in den Einstellungen ändern.")
            font.pixelSize: Theme.callout; color: Theme.secondary
        }
        Button {
            Layout.alignment: Qt.AlignHCenter
            text: qsTr("Weiter")
            highlighted: true
            onClicked: prompt.confirm()
        }
    }
}
