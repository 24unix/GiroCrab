import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// One setting (label, field, help) as in BankSetupSheet / AddBankSheet's setup step.
ColumnLayout {
    id: f
    property string key
    readonly property var entry: AppModel.settingEntry(key)
    signal edited(string value)
    spacing: 4
    Text { text: f.entry ? f.entry.label : f.key; font.pixelSize: Theme.callout + 1; font.weight: Font.Medium; color: Theme.text }
    TextArea {
        visible: f.key.indexOf("private_key") >= 0
        Layout.fillWidth: true; Layout.preferredHeight: 80
        Accessible.name: f.entry ? f.entry.label : f.key   // SecureField(label, …).labelsHidden() (ff91866)
        font.family: "monospace"; font.pixelSize: Theme.caption
        onTextChanged: if (visible) f.edited(text)
    }
    TextField {
        visible: f.key.indexOf("private_key") < 0
        Layout.fillWidth: true
        echoMode: (f.entry ? f.entry.is_secret : f.key.indexOf("secret") >= 0) ? TextInput.Password : TextInput.Normal
        placeholderText: f.entry && f.entry.value && !f.entry.is_secret ? f.entry.value : qsTr("Erforderlich")
        onTextChanged: if (visible) f.edited(text)
        Accessible.name: f.entry ? f.entry.label : f.key   // TextField(label, …).labelsHidden() (ff91866)
    }
    Text { visible: f.entry && f.entry.help !== ""; text: f.entry ? f.entry.help : ""; font.pixelSize: Theme.caption; color: Theme.secondary; wrapMode: Text.WordWrap; Layout.fillWidth: true }
    Text {
        visible: f.key === "fints.product_id"
        text: "<a href=\"https://www.fints.org/de/hersteller/produktregistrierung\">" + qsTr("Kostenlose FinTS-Produktregistrierung (Deutsche Kreditwirtschaft) öffnen") + "</a>"
        font.pixelSize: Theme.caption; color: Theme.accent; linkColor: Theme.accent
        onLinkActivated: link => Qt.openUrlExternally(link)
    }
    Text { visible: f.key === "fints.product_id"; text: qsTr("Die Registrierung dauert meist einige Tage. Bis dahin können Sie GiroCrab mit den Demo-Daten ausprobieren.")
           font.pixelSize: Theme.caption2; color: Theme.tertiary; wrapMode: Text.WordWrap; Layout.fillWidth: true }
}
