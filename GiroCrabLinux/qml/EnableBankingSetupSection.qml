import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtCore

// EnableBankingSetup.swift › EnableBankingSetupSection: short guide, key-file import and a
// check of the application before the first bank login. Edits `values` (setting key → text).
ColumnLayout {
    id: eb
    property var values: ({})
    signal edited(string key, string value)
    spacing: 12

    readonly property string idKey: "enablebanking.application_id"
    readonly property string pemKey: "enablebanking.private_key_pem"
    readonly property string redirectKey: "enablebanking.redirect_url"
    readonly property string redirect: {
        const v = (values[redirectKey] || "").trim()
        return v || AppModel.consentRedirectURL()
    }
    readonly property bool hasKey: (values[pemKey] || "") !== "" || !!(AppModel.settingEntry(pemKey) && AppModel.settingEntry(pemKey).has_value)
    /// Result of reading the key file: { ok, text }.
    property var keyNote: null
    property bool checking: false
    property var check: null
    property string checkError: ""

    function set(key, v) { edited(key, v) }
    // .onAppear: the redirect URL defaults to the one GiroCrab listens on.
    function fillRedirect() { if (visible && (values[redirectKey] || "") === "") set(redirectKey, AppModel.consentRedirectURL()) }
    onVisibleChanged: Qt.callLater(fillRedirect)
    onValuesChanged: Qt.callLater(fillRedirect)

    function runCheck() {
        if (!AppModel.isUnlocked) return
        checking = true
        AppModel.checkEnableBankingApplication((values[idKey] || "").trim(), values[pemKey] || "", redirect,
            r => { checking = false; check = r; checkError = "" },
            err => { checking = false; check = null; checkError = AppModel.parseCoreError(err).message })
    }

    FileDialog {
        id: keyDialog
        title: qsTr("Schlüsseldatei (.pem) wählen …")
        currentFolder: StandardPaths.writableLocation(StandardPaths.DownloadLocation)
        nameFilters: [qsTr("Privater Schlüssel (*.pem *.key *.txt)"), qsTr("Alle Dateien (*)")]
        onAccepted: {
            try {
                const k = AppModel.readEnableBankingKeyFile(selectedFile)
                eb.set(eb.pemKey, k.pem)
                if (k.applicationID) eb.set(eb.idKey, k.applicationID)
                eb.keyNote = { ok: true, text: k.applicationID ? qsTr("Schlüssel und Application-ID übernommen")
                                                            : qsTr("Schlüssel übernommen – Application-ID bitte eintragen") }
                eb.check = null
                eb.checkError = ""
                if (k.applicationID) Qt.callLater(eb.runCheck)
            } catch (e) {
                eb.keyNote = { ok: false, text: e.message }
            }
        }
    }

    // guide
    ColumnLayout {
        Layout.fillWidth: true
        spacing: 6
        Text { text: qsTr("So richten Sie Ihre kostenlose Enable-Banking-Anwendung ein:"); font.pixelSize: Theme.callout + 1; font.weight: Font.Medium; color: Theme.text; wrapMode: Text.WordWrap; Layout.fillWidth: true }
        Step { n: 1; text: qsTr("Auf enablebanking.com eine Anwendung registrieren: „Production“ wählen, den Schlüssel im Browser erzeugen lassen und diese Redirect-URL eintragen:") }
        RowLayout {
            Layout.leftMargin: 22
            spacing: 6
            TextEdit { text: eb.redirect; readOnly: true; selectByMouse: true; font.family: "monospace"; font.pixelSize: Theme.caption; color: Theme.text }
            IconButton { symbol: "doc.on.doc"; symbolSize: 13; ToolTip.text: qsTr("Redirect-URL kopieren"); onClicked: AppModel.copyToClipboard(eb.redirect) }
        }
        Step { n: 2; text: qsTr("Bei der Anwendung „Activate by linking accounts“ wählen und alle Konten verknüpfen, die GiroCrab sehen soll – nicht verknüpfte Konten liefert die Bank nicht.") }
        // importedAccounts: the accounts the MoneyMoney import attached to Enable Banking
        // connections – the ones to link while activating the application.
        Rectangle {
            visible: AppModel.psd2LinkHints.length > 0
            Layout.fillWidth: true; Layout.leftMargin: 22
            implicitHeight: hints.implicitHeight + 16
            radius: 8; color: Theme.canvas
            ColumnLayout {
                id: hints
                x: 8; y: 8; width: parent.width - 16
                spacing: 4
                Text { text: qsTr("Aus Ihrem MoneyMoney-Import:"); font.pixelSize: Theme.caption; font.weight: Font.Medium; color: Theme.text }
                Repeater {
                    model: AppModel.psd2LinkHints
                    ColumnLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 4
                        Text { text: modelData.bank_name; Layout.topMargin: 2; font.pixelSize: Theme.caption; font.weight: Font.Medium; color: Theme.text }
                        Repeater {
                            model: modelData.accounts
                            TextEdit {
                                required property var modelData
                                readOnly: true; selectByMouse: true
                                text: [modelData.name, modelData.iban !== "" ? Fmt.iban(modelData.iban) : (modelData.account_number !== "" ? qsTr("Konto %1").arg(modelData.account_number) : null)].filter(x => !!x).join(" · ")
                                font.pixelSize: Theme.caption; font.features: { "tnum": 1 }; color: Theme.secondary
                            }
                        }
                    }
                }
            }
        }
        Step { n: 3; text: qsTr("Hier die heruntergeladene .pem-Datei wählen. GiroCrab übernimmt Schlüssel und Application-ID und prüft die Anwendung.") }
        Text {
            Layout.leftMargin: 22
            text: "<a href=\"https://enablebanking.com/cp/applications\">" + qsTr("enablebanking.com/cp/applications öffnen") + "</a>"
            font.pixelSize: Theme.caption; color: Theme.accent; linkColor: Theme.accent
            onLinkActivated: link => Qt.openUrlExternally(link)
        }
    }
    Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }
    RowLayout {
        Layout.fillWidth: true
        spacing: 10
        IconButton { symbol: "key"; text: qsTr("Schlüsseldatei (.pem) wählen …"); tint: Theme.accent; onClicked: keyDialog.open() }
        SFIcon { visible: eb.keyNote !== null; symbol: eb.keyNote && eb.keyNote.ok ? "checkmark.circle" : "exclamationmark.triangle"; size: 12
                 color: eb.keyNote && eb.keyNote.ok ? Theme.inflow : Theme.negative }
        Text {
            visible: eb.keyNote !== null || eb.hasKey
            text: eb.keyNote ? eb.keyNote.text : qsTr("Schlüssel ist gespeichert")
            font.pixelSize: Theme.caption; wrapMode: Text.WordWrap; Layout.fillWidth: true
            color: eb.keyNote ? (eb.keyNote.ok ? Theme.inflow : Theme.negative) : Theme.secondary
        }
    }
    SettingsFormRow {
        label: qsTr("Application-ID")
        TextField {
            Layout.fillWidth: true; Layout.preferredWidth: 300
            font.family: "monospace"
            placeholderText: qsTr("wird aus dem Dateinamen übernommen")
            text: eb.values[eb.idKey] || ""
            onTextEdited: eb.set(eb.idKey, text)
        }
    }
    RowLayout {
        spacing: 10
        IconButton {
            symbol: "checkmark.shield"; text: qsTr("Anwendung prüfen"); tint: Theme.accent
            enabled: !eb.checking && (eb.values[eb.idKey] || "").trim() !== "" && (eb.values[eb.pemKey] || "") !== ""
            onClicked: eb.runCheck()
        }
        BusyIndicator { visible: eb.checking; running: eb.checking; implicitWidth: 18; implicitHeight: 18 }
    }
    // check result
    Text {
        visible: eb.checkError !== ""
        text: "✕ " + eb.checkError
        font.pixelSize: Theme.caption; color: Theme.negative; wrapMode: Text.WordWrap; Layout.fillWidth: true
    }
    Text {
        visible: eb.checkError === "" && eb.check !== null && eb.check.problems.length === 0
        text: "✓ " + qsTr("Anwendung „%1“ ist bereit (Production, aktiv, Redirect-URL eingetragen).").arg(eb.check ? eb.check.name : "")
        font.pixelSize: Theme.caption; color: Theme.inflow; wrapMode: Text.WordWrap; Layout.fillWidth: true
    }
    Repeater {
        model: eb.checkError === "" && eb.check ? eb.check.problems : []
        Text { required property string modelData; text: "⚠ " + modelData; font.pixelSize: Theme.caption; color: Theme.warning; wrapMode: Text.WordWrap; Layout.fillWidth: true }
    }

    component Step: RowLayout {
        property int n
        property string text
        Layout.fillWidth: true
        spacing: 8
        Text { text: parent.n + "."; font.pixelSize: Theme.caption; font.weight: Font.DemiBold; color: Theme.text; horizontalAlignment: Text.AlignRight; Layout.preferredWidth: 14; Layout.alignment: Qt.AlignTop }
        Text { text: parent.text; font.pixelSize: Theme.caption; color: Theme.secondary; wrapMode: Text.WordWrap; Layout.fillWidth: true }
    }
}
