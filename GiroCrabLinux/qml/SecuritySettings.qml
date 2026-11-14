import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// SettingsView.swift › SecuritySettings. Linux: the vault key lives in the Secret Service
// (KWallet / GNOME Schlüsselbund) instead of the Keychain; Touch ID and iCloud Sync are not
// part of the Linux app. The key backup ("Tresor-Schlüssel kopieren" / "Schlüssel einfügen …"
// of the iCloud section) lives in its own section here; like Swift the key is only copied,
// never shown. BankingPolicySection (BankingPolicyUI.swift) follows.
Item {
    id: pane
    readonly property string coreVersion: AppModel.core("core_version")
    /// AppVersionDisplay.text: the core version, the app version only when it differs.
    readonly property string versionText: {
        const app = Qt.application.version
        return app === "" || app === coreVersion ? coreVersion : coreVersion + " (App " + app + ")"
    }
    onVisibleChanged: if (visible) AppModel.vaultInfo = AppModel.core("vault_info")

    KeyPasteSheet { id: keyPaste }
    /// "Schlüssel kopiert (60 s)": the clipboard forgets the key after 60 s.
    property bool keyCopied: false
    Timer { id: keyCopiedReset; interval: 60000; onTriggered: pane.keyCopied = false }
    Connections {
        target: AppModel
        function onVaultStateChanged() { if (AppModel.vaultState !== "open") { pane.keyCopied = false; keyPaste.close() } }
    }
    readonly property var policy: AppModel.bankingPolicy
    /// BankingPolicySection.statusText
    readonly property string policyStatus: {
        const p = policy
        if (!p.enabled) return qsTr("Nicht aktiv (kein Prüfschlüssel in diesem Build)")
        const g = p.gate
        if (!g) {
            if (p.relies_on_bundled && p.bundled_valid_until_ms)
                return qsTr("Keine Sperre (Stand dieser Version, bis %1)").arg(new Date(p.bundled_valid_until_ms).toLocaleDateString(Qt.locale(), "d. MMM yyyy"))
            return !p.last_check_ms && !p.verified_online ? qsTr("Wird geprüft …") : qsTr("Keine Sperre")
        }
        if (g.reason === "checkUnavailable") return qsTr("Prüfung nicht möglich")
        return g.all ? qsTr("Alle Bankverbindungen gesperrt") : qsTr("Teilweise gesperrt")
    }

    ScrollView {
        id: scroll
        anchors.fill: parent
        contentWidth: availableWidth
        ColumnLayout {
            width: scroll.availableWidth - 40
            x: 20
            spacing: 18
            Item { implicitHeight: 2 }
            SettingsFormSection {
                title: qsTr("Tresor")
                enabled: AppModel.isUnlocked
                SettingsFormRow { label: qsTr("Verschlüsselung"); value: "SQLCipher 4 (AES-256)" }
                SettingsFormRow {
                    label: qsTr("Hauptschlüssel")
                    value: AppModel.isDemo ? qsTr("Demo-Schlüssel (Wegwerf)")
                        : AppModel.vaultInfo.keychain_bypassed ? qsTr("Entwickler-Schlüssel (GIROCRAB_NO_KEYCHAIN, Schlüsselbund unbenutzt)")
                        : qsTr("Schlüsselbund (Secret Service: KWallet / GNOME Schlüsselbund)")
                }
                SettingsFormRow { label: qsTr("Datei"); value: AppModel.isDemo ? "–" : (AppModel.vaultInfo.path || "–"); selectable: true }
                SettingsFormRow { label: qsTr("Version"); value: pane.versionText; selectable: true }
            }
            SettingsFormSection {
                title: qsTr("Tresor-Schlüssel")
                footer: qsTr("Der Schlüssel liegt im Schlüsselbund Ihrer Sitzung, nie neben der Tresordatei. Sichern Sie ihn, bevor Sie das System neu aufsetzen, und fügen Sie ihn auf einem anderen Rechner ein, um denselben Tresor zu öffnen.")
                RowLayout {
                    spacing: 8
                    IconButton {
                        symbol: "key"; text: pane.keyCopied ? qsTr("Schlüssel kopiert (60 s)") : qsTr("Tresor-Schlüssel kopieren"); tint: Theme.accent
                        enabled: AppModel.hasOwnVault && !AppModel.isDemo
                        onClicked: AppModel.exportVaultKey(k => {
                            if (AppModel.vaultState !== "open") return   // locked while the keyring answered
                            AppModel.copySecret(k)
                            pane.keyCopied = true
                            keyCopiedReset.restart()
                        })
                    }
                    IconButton {
                        symbol: "square.and.pencil"; text: qsTr("Schlüssel einfügen …"); tint: Theme.accent
                        // also while locked: restores a key that is missing from the keyring
                        enabled: AppModel.hasOwnVault ? !AppModel.isDemo : AppModel.vaultInfo.size > 0
                        onClicked: keyPaste.open()
                    }
                }
            }
            // BankingPolicySection (BankingPolicyUI.swift)
            SettingsFormSection {
                title: qsTr("Sicherheitssperre für Bankverbindungen")
                Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.callout + 1; color: Theme.secondary
                       text: qsTr("GiroCrab prüft regelmäßig, ob diese Version noch sicher mit Banken kommunizieren darf. Enthält sie eine Sicherheitslücke oder einen schweren Fehler im Bankzugang, sind Abrufe und Überweisungen bis zum Update gesperrt. Ihre Daten bleiben lesbar und exportierbar. Dafür lädt GiroCrab höchstens alle 15 Minuten eine signierte Datei von GitHub; dabei werden keine persönlichen Daten übertragen.") }
                SettingsFormRow { label: qsTr("Status"); value: pane.policyStatus }
                SettingsFormRow {
                    visible: pane.policy.enabled
                    label: qsTr("Letzte Prüfung")
                    value: pane.policy.last_check_ms ? Fmt.relative(pane.policy.last_check_ms / 1000) : qsTr("Noch nicht geprüft")
                }
                SettingsFormRow { visible: pane.policy.enabled && !!pane.policy.last_failure; label: qsTr("Letzter Fehler"); value: pane.policy.last_failure || "" }
                SettingsFormRow {
                    visible: pane.policy.enabled && pane.policy.sequence !== null && pane.policy.sequence !== undefined
                    label: qsTr("Richtlinie"); value: qsTr("Stand %1").arg(pane.policy.sequence)
                }
                RowLayout {
                    visible: !!pane.policy.debug_overrides
                    Layout.fillWidth: true; spacing: 6
                    SFIcon { symbol: "hammer"; size: 12; color: Theme.warning; Layout.alignment: Qt.AlignTop }
                    Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption; color: Theme.warning
                           text: qsTr("Debug-Build: Adresse, Schlüssel, Version oder Build-Datum sind per Umgebungsvariable überschrieben.") }
                }
                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    Button { visible: pane.policy.enabled; text: qsTr("Jetzt prüfen"); enabled: !AppModel.bankingPolicyChecking
                             onClicked: AppModel.withFreshBankingPolicy(null, true) }
                    BusyIndicator { visible: AppModel.bankingPolicyChecking; running: visible; implicitWidth: 18; implicitHeight: 18 }
                    Item { Layout.fillWidth: true }
                    Button { flat: true; text: qsTr("Mehr erfahren")
                             onClicked: Qt.openUrlExternally("https://github.com/GiroCrab/GiroCrab/blob/main/docs/banking-policy.md") }
                }
            }
            SettingsFormSection {
                title: qsTr("Datenschutz")
                Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.callout + 1; color: Theme.secondary
                       text: qsTr("GiroCrab verbindet sich direkt von diesem Gerät mit Ihren Banken. Es gibt keinen GiroCrab-Server und kein Tracking. PINs und TANs liegen nur für einen Abruf im Speicher und werden danach gelöscht.") }
            }
            SettingsFormSection {
                visible: AppModel.hasOwnVault && !AppModel.isDemo
                IconButton { symbol: "lock"; text: qsTr("Jetzt sperren"); tint: Theme.accent; onClicked: AppModel.lock() }
            }
            Item { implicitHeight: 8 }
        }
    }
}
