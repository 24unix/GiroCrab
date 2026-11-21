import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// ConnectionsUI.swift › PinSheet: login + PIN for one sync, optionally stored in the vault.
Sheet {
    id: sheet
    property var connection: AppModel.pendingLogin
    readonly property var d: connection ? AppModel.descriptor(connection.connector) : null
    readonly property bool isTR: connection && connection.connector === "TradeRepublic"
    /// AppModel+Rah.swift › usesRah10 (#460): the secret is the key file's password, the login is fixed.
    readonly property bool isRah10: !!connection && connection.connector === "FinTsGeneric"
        && (AppModel.run(() => AppModel.core("connection_key", { connection_id: connection.id })) || "").endsWith(":rah10")
    readonly property string secretLabel: isRah10 ? qsTr("Passwort der Schlüsseldatei") : (d ? d.secret_label : qsTr("PIN"))
    visible: connection !== null
    sheetWidth: 440
    onAboutToShow: {
        login.text = connection.login_name
        secret.text = ""
        const st = AppModel.connectionStatus(connection.id)
        savePin.checked = st ? st.has_pin : false
        secret.forceActiveFocus()
    }
    // the PIN never outlives the sheet (cancel, Escape, lock)
    onRejected: { secret.text = ""; AppModel.cancelPendingLogin() }
    onClosed: secret.text = ""
    function start() {
        if (secret.text === "") return
        const l = isTR ? AppModel.core("normalize_phone_number", { input: login.text }) : login.text.trim()
        if (l !== connection.login_name) AppModel.updateConnection(connection.id, connection.display_name, l)
        const s = secret.text
        secret.text = ""
        AppModel.setConnectionPin(connection.id, savePin.checked ? s : null)
        const current = AppModel.connections.find(c => c.id === connection.id) || connection
        AppModel.startSync(current, s)
    }
    ColumnLayout {
        width: sheet.availableWidth
        spacing: 14
        RowLayout {
            spacing: 10
            SymbolTile { symbol: sheet.connection ? sheet.connection.sf_symbol : ""; size: 34; tint: Theme.accent }
            ColumnLayout { spacing: 0; Layout.fillWidth: true
                Text { text: sheet.connection ? qsTr("Anmeldung bei %1").arg(AppModel.masking(sheet.connection.display_name)) : ""; font.pixelSize: Theme.body + 1; font.weight: Font.DemiBold; color: Theme.text }
                Text { text: sheet.d ? sheet.d.protocol : ""; font.pixelSize: Theme.caption; color: Theme.secondary } }
            SyncBatchProgressLabel {}
        }
        DemoHintBanner {
            visible: AppModel.demoActive || (sheet.connection && sheet.connection.bank_code === "99999999")
            Layout.fillWidth: true
            onFill: { login.text = "demo"; secret.text = "12345" }
        }
        ColumnLayout { spacing: 4; Layout.fillWidth: true
            Text { text: sheet.d ? sheet.d.login_label : qsTr("Anmeldung"); font.pixelSize: Theme.caption; color: Theme.secondary }
            TextField { id: login; Layout.fillWidth: true; placeholderText: sheet.d ? sheet.d.login_label : ""; enabled: !sheet.isRah10; Sensitive {} }
            Text { visible: sheet.isTR && login.text !== ""; font.pixelSize: Theme.caption2; color: Theme.secondary
                   text: { const n = sheet.isTR ? AppModel.core("normalize_phone_number", { input: login.text }) : ""; return n === login.text ? qsTr("Format korrekt (E.164)") : qsTr("Wird gesendet als %1").arg(AppModel.masking(n)) } }
        }
        ColumnLayout { spacing: 4; Layout.fillWidth: true
            Text { text: sheet.secretLabel; font.pixelSize: Theme.caption; color: Theme.secondary }
            TextField { id: secret; Layout.fillWidth: true; echoMode: TextInput.Password; onAccepted: sheet.start() }
            CheckBox { id: savePin; text: sheet.isRah10 ? qsTr("Passwort im Tresor speichern") : qsTr("PIN im Tresor speichern"); font.pixelSize: Theme.caption
                       ToolTip.text: qsTr("Verschlüsselt in der SQLCipher-Datenbank; beim nächsten Abruf wird nicht mehr gefragt."); ToolTip.visible: hovered }
        }
        Text {
            Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption; color: Theme.secondary
            text: sheet.isRah10
                  ? (savePin.checked ? qsTr("Das Passwort wird verschlüsselt im Tresor gespeichert.") : qsTr("Das Passwort wird nur für diesen Abruf verwendet."))
                  : (savePin.checked ? qsTr("Die PIN wird verschlüsselt im Tresor gespeichert.") : qsTr("Die PIN wird nur für diesen Abruf verwendet und nie gespeichert."))
        }
        // Trade Republic: the AWS WAF may block the plain login – browser login instead.
        Rectangle { visible: sheet.isTR; Layout.fillWidth: true; height: 1; color: Theme.border }
        ColumnLayout {
            visible: sheet.isTR
            Layout.fillWidth: true
            spacing: 6
            Text { text: qsTr("Anmeldung blockiert (HTTP 403/426)?"); font.pixelSize: Theme.caption; font.weight: Font.DemiBold; color: Theme.text }
            Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption; color: Theme.secondary
                   text: qsTr("Melden Sie sich im eingebauten Browser-Fenster an. GiroCrab übernimmt danach die Sitzung (tr_session) für den Abruf.") }
            IconButton {
                symbol: "safari"; text: qsTr("Im Browser-Fenster anmelden …"); tint: Theme.accent
                onClicked: {
                    const l = AppModel.core("normalize_phone_number", { input: login.text })
                    if (l !== sheet.connection.login_name) AppModel.updateConnection(sheet.connection.id, sheet.connection.display_name, l)
                    const c = AppModel.connections.find(x => x.id === sheet.connection.id) || sheet.connection
                    AppModel.pendingLogin = null
                    AppModel.webLoginConnection = c
                }
            }
        }
        SyncPromptButtons {
            Layout.fillWidth: true
            defaultTitle: qsTr("Abrufen")
            defaultEnabled: secret.text !== "" && login.text.trim() !== ""
            onCancel: AppModel.cancelPendingLogin()
            onAccept: sheet.start()
        }
    }
}
