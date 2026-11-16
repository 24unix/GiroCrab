import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// HelpView.swift: searchable help & FAQ (Hilfe › GiroCrab-Hilfe, Strg+?). Topics and shortcut
// labels come in German and English straight from HelpCatalog (build.rs › help.json, core call
// "help_content"); the vault topic and the shortcut keys are adapted to Linux.
ApplicationWindow {
    id: win
    // `--dark` / `--light`: the controls follow the forced appearance (Theme.forcedPalette)
    Binding on palette { when: Theme.forced !== ""; value: Theme.forcedPalette }
    font.pointSize: Theme.controlPointSize   // appTextSize (#343)
    title: qsTr("GiroCrab-Hilfe")
    width: 640; height: 720
    minimumWidth: 480; minimumHeight: 420
    color: Theme.canvas
    visible: AppModel.showHelp
    onClosing: AppModel.showHelp = false
    onVisibleChanged: if (visible) { requestActivate(); raise(); searchField.forceActiveFocus() }
    function focusSearch() { searchField.forceActiveFocus() }
    Shortcut { sequences: [StandardKey.Close]; onActivated: win.close() }

    property string query: ""

    readonly property var help: AppModel.run(() => AppModel.core("help_content")) || ({ topics: [], shortcuts: {} })
    readonly property string language: (AppModel.run(() => AppModel.core("language_state")) || { running: "de" }).running
    /// Shortcut label in the UI language: the Mac's English label, else the Linux one (en-linux.json).
    function shortcutLabel(de) { return language === "en" ? (help.shortcuts[de] || qsTr(de)) : de }

    /// Tastaturkürzel, geprüft gegen die Menüs in Main.qml.
    readonly property var shortcuts: [
        ["Strg+R", "Alle Konten abrufen"], ["Strg+F", "Suchen"], ["Strg+K", "Befehlspalette"], ["Strg+,", "Einstellungen"],
        ["Strg+?", "GiroCrab-Hilfe"], ["Strg+Alt+B", "Problem melden"],["Strg+Meta+L", "Tresor sperren"], ["Strg+Umschalt+N", "Neue Kontogruppe"],
        ["Strg+N", "Neue Überweisung"], ["Strg+Alt+K", "Regeln"],
        ["C", "Kategorie wählen (in der Buchungsliste)"], ["R", "Regel aus Buchung erstellen (in der Buchungsliste)"],
        ["Strg+Meta+C / Strg+Meta+R", "Kategorisieren / Regel erstellen (Menü Buchung)"],
        ["Strg+Umschalt+U", "Als geprüft markieren"], ["Strg+Umschalt+Alt+U", "Alle Buchungen als gelesen markieren"],
        ["Strg+Y", "Beleg in Quick Look"],
        ["Strg+Meta+↓ / Strg+Meta+↑", "Nächste / vorherige Buchung"], ["Strg+1 … Strg+3", "Buchungsbereich wechseln"],
        ["Strg+P", "Drucken"],
        ["Strg+Alt+I", "Informationen ein-/ausblenden"], ["Strg+Umschalt+D", "Demo-Daten / eigenen Tresor anzeigen"]]

    /// The vault topic on Linux: Secret Service instead of the Keychain, no iCloud sync.
    readonly property var linuxVault: ({ id: "vault", icon: "lock.shield",
        title: { de: "Tresor & Datenschutz", en: "Vault & privacy" },
        body: { de: "**100 % lokal:** Alle Daten liegen in einer verschlüsselten SQLite/SQLCipher-Datenbank auf deinem Rechner. GiroCrab hat keinen eigenen Server und sendet nichts an Dritte; Abfragen gehen nur direkt an deine Bank bzw. den gewählten Dienst.\n\n"
              + "**Schlüssel:** Der Tresorschlüssel liegt im Schlüsselbund deiner Sitzung (Secret Service: KWallet oder GNOME Schlüsselbund). Beim Entsperren fragt der Schlüsselbund gegebenenfalls nach seinem Passwort.\n\n"
              + "**Tresor sperren:** *Ablage › Tresor sperren* (Strg+Meta+L) oder *Einstellungen › Sicherheit › Jetzt sperren*.\n\n"
              + "**Schlüssel sichern:** Unter *Einstellungen › Sicherheit › Tresor-Schlüssel* zeigst du den Schlüssel an (Base64) oder fügst ihn auf einem anderen Rechner wieder ein. Ohne Schlüssel lässt sich der Tresor nicht öffnen.",
                en: "**100 % local:** All data lives in an encrypted SQLite/SQLCipher database on your computer. GiroCrab has no server of its own and sends nothing to third parties; requests only go directly to your bank or the chosen service.\n\n"
                  + "**Key:** The vault key is stored in your session's keyring (Secret Service: KWallet or GNOME Keyring). When unlocking, the keyring may ask for its password.\n\n"
                  + "**Lock the vault:** *File › Lock Vault* (Ctrl+Meta+L) or *Settings › Security › Lock Now*.\n\n"
                  + "**Back up the key:** Under *Settings › Security › Vault key* you can show the key (Base64) or paste it on another computer. Without the key the vault cannot be opened." },
        keywords: ["sqlcipher", "verschlüsselung", "encryption", "schlüsselbund", "keyring", "kwallet", "gnome", "secret service", "sperren", "lock", "datenschutz", "privacy", "schlüssel", "key"] })
    readonly property var topics: help.topics.map(t => t.id === "vault" ? linuxVault : t)
        .map(t => ({ id: t.id, icon: t.icon, title: t.title[language] || t.title.de, body: t.body[language] || t.body.de, keywords: t.keywords }))

    /// HelpTopic.matches: all terms must occur (case and diacritics ignored).
    function matches(hay) {
        const terms = query.split(/\s+/).filter(t => t !== "")
        const h = Fmt.fold(hay)
        return terms.every(t => h.indexOf(Fmt.fold(t)) >= 0)
    }
    readonly property var visibleTopics: topics.filter(t => matches([t.title, t.body].concat(t.keywords).join(" ")))
    readonly property bool showShortcuts: matches(shortcuts.map(s => s[0] + " " + Fmt.keys(s[0]) + " " + s[1] + " " + shortcutLabel(s[1])).join(" ") + " Tastaturkürzel keyboard shortcuts")

    header: ToolBar {
        background: Rectangle { color: Theme.canvas; Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border } }
        RowLayout {
            anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
            Text { text: qsTr("Hilfe & FAQ"); font.pixelSize: Theme.title3; font.weight: Font.DemiBold; color: Theme.text; Layout.fillWidth: true }
            TextField {
                id: searchField
                Layout.preferredWidth: 240
                placeholderText: qsTr("In der Hilfe suchen")
                leftPadding: 28
                SFIcon { symbol: "magnifyingglass"; size: 14; anchors.verticalCenter: parent.verticalCenter; x: 8 }
                onTextEdited: win.query = text
                Component.onCompleted: text = win.query
                Keys.onEscapePressed: { text = ""; win.query = "" }
            }
        }
    }

    ScrollView {

        ScrollBar.vertical: ScrollViewBar {}
        id: scroll
        anchors.fill: parent
        contentWidth: availableWidth
        ColumnLayout {
            width: scroll.availableWidth - 40
            x: 20
            spacing: 18
            Item { implicitHeight: 4 }
            Repeater {
                model: win.visibleTopics
                ColumnLayout {
                    id: topic
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 6
                    RowLayout { spacing: 7
                        SFIcon { symbol: topic.modelData.icon; size: 16; color: Theme.accent }
                        Text { text: topic.modelData.title; font.pixelSize: Theme.title3; font.weight: Font.DemiBold; color: Theme.text } }
                    Card {
                        Layout.fillWidth: true
                        TextEdit {
                            width: parent.width
                            readOnly: true; selectByMouse: true
                            textFormat: TextEdit.MarkdownText
                            text: topic.modelData.body
                            wrapMode: Text.WordWrap
                            font.pixelSize: Theme.body; color: Theme.text
                        }
                    }
                }
            }
            ColumnLayout {
                visible: win.showShortcuts
                Layout.fillWidth: true
                spacing: 6
                RowLayout { spacing: 7
                    SFIcon { symbol: "keyboard"; size: 16; color: Theme.accent }
                    Text { text: qsTr("Tastaturkürzel"); font.pixelSize: Theme.title3; font.weight: Font.DemiBold; color: Theme.text } }
                SettingsFormSection {
                    Repeater {
                        model: win.shortcuts
                        SettingsFormRow { required property var modelData; label: win.shortcutLabel(modelData[1]); value: Fmt.keys(modelData[0]) }
                    }
                }
            }
            // ContentUnavailableView.search
            Text {
                visible: win.visibleTopics.length === 0 && !win.showShortcuts
                Layout.fillWidth: true; Layout.topMargin: 40
                horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                text: qsTr("Keine Ergebnisse für „%1“").arg(win.query)
                font.pixelSize: Theme.title3; color: Theme.secondary
            }
            SettingsFormSection {
                visible: win.query === ""
                title: qsTr("Support")
                // BugReportButton (#301)
                LinkRow { symbol: "ladybug"; text: qsTr("Problem melden …"); onActivated: AppModel.showBugReport = true }
                LinkRow { symbol: "globe"; text: qsTr("Webseite & Dokumentation (girocrab.de)"); url: "https://girocrab.de" }
                LinkRow { symbol: "ladybug"; text: qsTr("Fehler melden / Issue erstellen (GitHub)"); url: "https://github.com/GiroCrab/GiroCrab/issues" }
                LinkRow { symbol: "bubble.left.and.bubble.right"; text: qsTr("Community & Diskussionen (GitHub)"); url: "https://github.com/GiroCrab/GiroCrab/discussions" }
            }
            Item { implicitHeight: 8 }
        }
    }

    component LinkRow: RowLayout {
        id: lr
        property string symbol
        property string text
        property string url
        signal activated()
        spacing: 7
        SFIcon { symbol: lr.symbol; size: 14; color: Theme.accent }
        Text { text: lr.text; font.pixelSize: Theme.body; color: Theme.accent
               MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: lr.url !== "" ? Qt.openUrlExternally(lr.url) : lr.activated() } }
    }
}
