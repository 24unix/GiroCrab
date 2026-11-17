import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import QtCore

// Rah10AddForm.swift + AppModel+Rah.swift (#460): Commerzbank access with an existing HBCI
// key file (RDH profile 10). Imports a copy into the encrypted vault; the source file stays
// untouched. Linux hands the core the chosen path (src/dispatch.rs › keyfile_bytes reads it,
// at most 1 MB) instead of reading the bytes in the UI like Rah10KeyfileReader.swift.
ColumnLayout {
    id: form
    /// AddBankSheet: closed after a successful import (`onAdded`).
    property var host
    spacing: 10
    property string path: ""
    property string fileError: ""
    property bool busy: false
    property var info: null                 // Rah10KeyfileInfo { blz, needs_bank_keys }
    property var candidates: []             // [Rah10BankKeyCandidate]
    property var expected: ({})             // key_type → typed fingerprint
    /// Drops the answers of a file/password that has changed meanwhile.
    property int generation: 0
    /// AddBankSheet waits for `commit()` to finish instead of closing right away.
    readonly property bool commitsAsync: true

    function normalized(value) { return (value || "").replace(/[\s:]/g, "").toUpperCase() }
    function matches(key) { return normalized(expected[key.key_type]) === key.fingerprint }
    readonly property bool canAdd: {
        if (path === "" || password.text === "" || busy || !info) return false
        return !info.needs_bank_keys || (candidates.length === 2 && candidates.every(k => matches(k)))
    }
    function resetInspection() { generation++; info = null; candidates = []; expected = ({}) }

    /// inspectFile › AppModel.inspectRah10File (offline: password and file format)
    function inspectFile() {
        if (busy) return
        busy = true; fileError = ""
        const gen = ++generation
        AppModel.coreAsync("inspect_rah10_keyfile", { path: path, password: password.text }, i => {
            if (gen !== generation) return
            busy = false; info = i
        }, err => {
            if (gen !== generation) return
            busy = false; info = null; fileError = AppModel.parseCoreError(err).message
        })
    }
    /// fetchKeys › AppModel.fetchRah10BankKeys: the bank's public keys (network, anonymous
    /// first-key request) after a fresh look at the banking policy.
    function fetchKeys() {
        if (busy || !info) return
        busy = true; fileError = ""; candidates = []; expected = ({})
        const gen = generation
        AppModel.withFreshBankingPolicy(() => {
            if (gen !== generation) { busy = false; return }
            AppModel.coreAsync("rah10_bank_key_candidates", { blz: info.blz }, keys => {
                if (gen !== generation) return
                busy = false; candidates = keys
            }, err => {
                if (gen !== generation) return
                busy = false; fileError = AppModel.parseCoreError(err).message
            })
        })
    }
    /// commit › AppModel.addRah10Connection: import, then the first sync with the password.
    function commit() {
        if (!canAdd) return
        busy = true
        const args = { path: path, password: password.text, display_name: name.text,
                       bank_keys: candidates, expected_fingerprints: candidates.map(k => expected[k.key_type] || "") }
        const secret = password.text
        AppModel.withFreshBankingPolicy(() => {
            if (!AppModel.bankingAllowsAdding(AppModel.bankingGateForNew("FinTsGeneric"))) { busy = false; return }
            if (AppModel.demoActive && AppModel.hasOwnVault) AppModel.useVault(false)
            AppModel.coreAsync("add_rah10_connection_with_bank_keys", args, id => {
                busy = false
                password.text = ""; path = ""
                AppModel.reloadSettings()
                if (form.host) form.host.close()
                // the first sync needs the new connection, which the async reload brings
                AppModel.reloadAccounts(() => {
                    const c = AppModel.connections.find(x => x.id === id)
                    if (c) AppModel.startSync(c, secret)
                })
            }, err => {
                busy = false
                AppModel.errorMessage = AppModel.parseCoreError(err).message
            })
        })
    }

    Text { text: qsTr("Schlüsseldatei"); font.pixelSize: Theme.callout; font.weight: Font.DemiBold; color: Theme.secondary }
    GridLayout {
        columns: 2; columnSpacing: 12; rowSpacing: 8; Layout.fillWidth: true
        enabled: !form.busy
        Item { implicitWidth: 1 }
        Button {
            Layout.fillWidth: true
            icon.name: SF.icon("doc.badge.key")
            text: form.path === "" ? qsTr("HBCI-Schlüsseldatei auswählen") : form.path.split("/").pop()
            onClicked: picker.open()
            Sensitive {}
        }
        Text { text: qsTr("Anzeigename"); color: Theme.text }
        TextField { id: name; Layout.fillWidth: true; text: "Commerzbank (RAH-10)"; Sensitive {} }
        Text { text: qsTr("Passwort der Schlüsseldatei"); color: Theme.text }
        TextField {
            id: password
            Layout.fillWidth: true; echoMode: TextInput.Password
            onTextChanged: { form.fileError = ""; form.resetInspection() }
            onAccepted: if (form.path !== "" && text !== "") form.inspectFile()
        }
        Item { implicitWidth: 1 }
        Button {
            Layout.alignment: Qt.AlignLeft
            text: qsTr("Datei prüfen")
            enabled: form.path !== "" && password.text !== "" && !form.busy
            onClicked: form.inspectFile()
        }
        Text { visible: form.info !== null; text: qsTr("Bankleitzahl"); color: Theme.text }
        Text { visible: form.info !== null; text: form.info ? form.info.blz : ""; color: Theme.secondary }
    }
    RowLayout {
        visible: form.info !== null
        spacing: 6
        SFIcon { symbol: "checkmark.shield"; size: 14; color: Theme.inflow }
        Text { text: qsTr("Passwort und Schlüsseldatei geprüft"); color: Theme.text }
    }
    Button {
        visible: form.info !== null && form.info.needs_bank_keys
        text: qsTr("Öffentliche Bankschlüssel abrufen")
        enabled: !form.busy
        onClicked: form.fetchKeys()
    }
    Text { visible: form.fileError !== ""; text: form.fileError; Layout.fillWidth: true; wrapMode: Text.WordWrap; color: Theme.negative }
    RowLayout {
        visible: form.busy
        spacing: 8
        BusyIndicator { running: form.busy; implicitWidth: 18; implicitHeight: 18 }
        Text { text: qsTr("Einrichtung läuft …"); color: Theme.secondary }
    }
    Text {
        Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption; color: Theme.secondary
        text: qsTr("GiroCrab übernimmt eine Kopie in den verschlüsselten Tresor. Die Originaldatei bleibt unverändert. Unterstützt zunächst Konto-, Salden- und Umsatzabrufe mit bestehenden Commerzbank-Zugängen. Verwenden Sie denselben Schlüssel nicht parallel in anderer Bankingsoftware. GiroCrab reserviert pro Abruf 10.000 Signaturzähler; ungenutzte Werte bleiben verbraucht und die Originaldatei behält ihren alten Zähler. Dadurch kann es bei paralleler Nutzung zu Zählerkonflikten kommen.")
    }

    // „Bankschlüssel unabhängig bestätigen“
    ColumnLayout {
        visible: form.candidates.length > 0
        Layout.fillWidth: true; Layout.topMargin: 6
        spacing: 10
        enabled: !form.busy
        Text { text: qsTr("Bankschlüssel unabhängig bestätigen"); font.pixelSize: Theme.callout; font.weight: Font.DemiBold; color: Theme.secondary }
        Button {
            flat: true
            text: qsTr("Prüfwerte auf der Commerzbank-Website öffnen")
            onClicked: Qt.openUrlExternally("https://www.commerzbank.de/service/kommunikationsadressen-ports-und-oeffentlicher-bankschluessel-fuer-hbci/")
        }
        Repeater {
            model: form.candidates
            ColumnLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: 6
                Text { text: modelData.key_type === "S" ? qsTr("Signaturschlüssel") : qsTr("Verschlüsselungsschlüssel")
                       font.pixelSize: Theme.body + 1; font.weight: Font.DemiBold; color: Theme.text }
                Text { text: qsTr("%1 Bit · Schlüssel %2, Version %3").arg(modelData.bits).arg(modelData.number).arg(modelData.version)
                       font.pixelSize: Theme.caption; color: Theme.secondary }
                TextEdit { text: modelData.fingerprint; readOnly: true; selectByMouse: true; Layout.fillWidth: true; wrapMode: TextEdit.WrapAnywhere
                           font.family: "monospace"; font.pixelSize: Theme.caption; color: Theme.text }
                TextField {
                    Layout.fillWidth: true
                    placeholderText: qsTr("SHA-256-Prüfwert laut Commerzbank")
                    inputMethodHints: Qt.ImhNoPredictiveText
                    onTextEdited: { const x = Object.assign({}, form.expected); x[modelData.key_type] = text; form.expected = x }
                }
                RowLayout {
                    visible: form.matches(modelData)
                    spacing: 6
                    SFIcon { symbol: "checkmark.shield"; size: 13; color: Theme.inflow }
                    Text { text: qsTr("Prüfwerte stimmen überein"); font.pixelSize: Theme.caption; color: Theme.inflow }
                }
            }
        }
        Text {
            Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption; color: Theme.secondary
            text: qsTr("Die empfangenen Schlüssel sind noch nicht vertrauenswürdig. Tragen Sie für beide Schlüssel den vollständigen SHA-256-Prüfwert aus der offiziellen Commerzbank-Quelle ein. Ein abweichender Prüfwert verhindert die Übernahme.")
        }
    }

    FileDialog {
        id: picker
        title: qsTr("HBCI-Schlüsseldatei auswählen")
        fileMode: FileDialog.OpenFile
        currentFolder: StandardPaths.writableLocation(StandardPaths.HomeLocation)
        onAccepted: {
            form.resetInspection()
            form.path = AppModel.localPath(selectedFile)
            form.fileError = ""
            password.text = ""
        }
    }
}
