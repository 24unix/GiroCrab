import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// SettingsView.swift › GeneralSettings. Language, Mitteilungen, Saldoverlauf (bars) and
// Händler-Logos are not on Linux yet (no translations, no announcement feed, line chart
// only, no online logos).
ScrollView {
    id: pane
    contentWidth: availableWidth
    ColumnLayout {
        width: pane.availableWidth - 40
        x: 20
        spacing: 18
        Item { implicitHeight: 2 }
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
