import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// SettingsView.swift › GeneralSettings. Mitteilungen, Saldoverlauf (bars) and Händler-Logos
// are not on Linux yet (no announcement feed, line chart only, no online logos).
ScrollView {
    id: pane
    contentWidth: availableWidth
    /// LanguagePreference: { choice: "system" | "de" | "en", system, running }.
    property var language: AppModel.run(() => AppModel.core("language_state")) || ({ choice: "system", system: "de", running: "de" })
    /// AppLanguage.nativeName: language names in their own language, as in the system settings.
    function nativeName(code) { return ({ de: "Deutsch", en: "English" })[code] || code }
    readonly property string effectiveLanguage: language.choice === "system" ? language.system : language.choice
    ColumnLayout {
        width: pane.availableWidth - 40
        x: 20
        spacing: 18
        Item { implicitHeight: 2 }
        // LanguagePreference.swift › LanguageSettingsSection
        SettingsFormSection {
            footer: qsTr("„Systemsprache“ folgt der Sprache Ihrer Arbeitsumgebung (z. B. Systemeinstellungen › Region & Sprache).")
            SettingsFormRow {
                label: qsTr("Sprache")
                AppComboBox {
                    Layout.preferredWidth: 200
                    model: [{ id: "system", title: qsTr("Systemsprache (%1)").arg(pane.nativeName(pane.language.system)) },
                            { id: "de", title: pane.nativeName("de") }, { id: "en", title: pane.nativeName("en") }]
                    textRole: "title"; valueRole: "id"
                    currentIndex: ["system", "de", "en"].indexOf(pane.language.choice)
                    onActivated: {
                        AppModel.run(() => AppModel.core("set_language_choice", { choice: currentValue }))
                        pane.language = AppModel.run(() => AppModel.core("language_state")) || pane.language
                    }
                }
            }
            SettingsFormRow {
                visible: pane.effectiveLanguage !== pane.language.running
                label: qsTr("Die neue Sprache wird nach einem Neustart verwendet.")
                Button {
                    text: qsTr("Neu starten")
                    onClicked: { AppModel.run(() => AppModel.core("request_relaunch")); Qt.quit() }
                }
            }
        }
        SettingsFormSection {
            title: qsTr("Ansicht")
            CheckBox {
                text: qsTr("Auswertungen in der Übersicht anzeigen")
                checked: AppModel.showStatistics
                onToggled: AppModel.showStatistics = checked
            }
            Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption; color: Theme.secondary
                   text: qsTr("Blendet Saldoverlauf, Cashflow und Budgets über der Buchungsliste aus. Auch im Menü Ansicht umschaltbar.") }
        }
        SettingsFormSection {
            title: qsTr("Buchungen")
            SettingsFormRow {
                label: qsTr("Als geprüft markieren")
                AppComboBox {
                    Layout.preferredWidth: 200
                    model: AppModel.autoReviewDelays
                    textRole: "title"; valueRole: "id"
                    currentIndex: AppModel.autoReviewDelays.findIndex(d => d.id === AppModel.autoReviewDelay)
                    onActivated: AppModel.autoReviewDelay = currentValue
                }
            }
            Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption; color: Theme.secondary
                   text: qsTr("Eine ausgewählte Buchung gilt nach dieser Zeit als geprüft – wie eine gelesene E-Mail. Bei Mehrfachauswahl nie.") }
        }
        Item { implicitHeight: 8 }
    }
}
