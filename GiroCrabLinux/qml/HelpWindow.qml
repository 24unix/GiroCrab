import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// HelpView.swift: searchable help & FAQ (Hilfe › GiroCrab-Hilfe, Strg+?). German texts of
// HelpCatalog; the vault topic and the shortcut list are adapted to Linux.
ApplicationWindow {
    id: win
    // `--dark` / `--light`: the controls follow the forced appearance (Theme.forcedPalette)
    Binding on palette { when: Theme.forced !== ""; value: Theme.forcedPalette }
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

    /// Tastaturkürzel, geprüft gegen die Menüs in Main.qml.
    readonly property var shortcuts: [
        ["Strg+R", "Alle Konten abrufen"], ["Strg+F", "Suchen"], ["Strg+K", "Befehlspalette"], ["Strg+,", "Einstellungen"],
        ["Strg+?", "GiroCrab-Hilfe"], ["Strg+Meta+L", "Tresor sperren"], ["Strg+Umschalt+N", "Neue Kontogruppe"],
        ["Strg+N", "Neue Überweisung"], ["Strg+Alt+K", "Regeln"],
        ["C", "Kategorie wählen (in der Buchungsliste)"], ["R", "Regel aus Buchung erstellen (in der Buchungsliste)"],
        ["Strg+Meta+C / Strg+Meta+R", "Kategorisieren / Regel erstellen (Menü Buchung)"],
        ["Strg+Umschalt+U", "Als geprüft markieren"], ["Strg+Umschalt+Alt+U", "Alle als gelesen markieren"],
        ["Strg+Y", "Beleg in Quick Look"],
        ["Strg+Meta+↓ / Strg+Meta+↑", "Nächste / vorherige Buchung"], ["Strg+1 … Strg+3", "Buchungsbereich wechseln"],
        ["Strg+P", "Drucken"],
        ["Strg+Alt+I", "Informationen ein-/ausblenden"], ["Strg+Umschalt+D", "Demo-Daten / eigenen Tresor anzeigen"]]

    readonly property var topics: [
        { id: "start", icon: "flag.checkered", title: "Erste Schritte & MoneyMoney-Import",
          body: "Beim ersten Start legt GiroCrab einen **lokalen, verschlüsselten Tresor** an. Danach gibt es zwei Wege, Buchungen zu laden: Bank direkt verbinden (siehe „Banken verbinden“) oder bestehende Daten importieren.\n\n"
              + "**MoneyMoney-Import:** *Ablage › Aus MoneyMoney importieren …* liest die MoneyMoney-Datenbank (Konten, Buchungen, Kategorien) oder eine CSV-Datei. Der Import kann gefahrlos wiederholt werden, bereits vorhandene Buchungen werden nicht doppelt angelegt.\n\n"
              + "**Startsaldo & Kalibrieren:** Konten ohne Banksaldo (z. B. CSV-Import oder Kreditkarten-Portale) kennen nur die importierten Umsätze. Damit der Kontostand stimmt, trägst du bei „Startsaldo & Kalibrieren“ den echten Saldo zu einem Stichtag ein. GiroCrab rechnet den Anfangssaldo daraus zurück und hält den Verlauf danach konsistent.",
          keywords: ["import", "csv", "moneymoney", "startsaldo", "opening balance", "kalibrieren", "calibrate"] },
        { id: "fints", icon: "building.columns", title: "Banken verbinden: FinTS / HBCI",
          body: "FinTS fragt deine Bank direkt ab, ohne Zwischenserver. Gehe auf *Ablage › Bank hinzufügen …* und wähle FinTS.\n\n"
              + "- **Registrierung:** GiroCrab nutzt standardmäßig seine **eingebaute FinTS-Registrierung**. Wenn du lieber eine eigene Produkt-ID der Deutschen Kreditwirtschaft verwendest, trage sie unter *Einstellungen › Banken › FinTS-Registrierung* ein.\n"
              + "- **Anmeldung:** Viele Banken verlangen die **Anmelde-/Legitimations-ID** (VR-NetKey, Benutzerkennung) statt der Kontonummer. Wenn die Anmeldung scheitert, probiere diese Kennung.\n"
              + "- **PIN:** Die Online-Banking-PIN ist oft nur 5-stellig. Sie wird im verschlüsselten Tresor gespeichert, nicht im Klartext.\n"
              + "- **TAN:** Das TAN-Verfahren (pushTAN, chipTAN, …) wählst du beim Hinzufügen; der TAN-Dialog erscheint beim Abruf.",
          keywords: ["hbci", "fints", "pin", "tan", "produkt-id", "registrierung", "registration", "anmeldename", "login"] },
        { id: "enable-banking", icon: "network", title: "Banken verbinden: Enable Banking (PSD2 – C24, N26 …)",
          body: "Für Banken ohne FinTS (z. B. C24, N26) nutzt GiroCrab PSD2 über **Enable Banking**. Du brauchst dafür eine kostenlose, **persönliche App** bei Enable Banking:\n\n"
              + "1. Auf **enablebanking.com** registrieren und im Control Panel eine neue Anwendung anlegen (Umgebung „Production“, Zugriff auf eigene Konten).\n"
              + "2. Als **Privacy-Policy-URL** und **Terms-of-Service-URL** jeweils `https://girocrab.de` eintragen.\n"
              + "3. Beim Erstellen wird ein privater Schlüssel als **.pem-Datei** erzeugt. Diese Datei in GiroCrab unter *Bank hinzufügen › Enable Banking* hochladen, dazu die Application-ID eintragen.\n"
              + "4. Bank auswählen und im Browser freigeben. Danach die Konten in GiroCrab verknüpfen.\n"
              + "5. **C24:** Beim Freigeben wird die Telefonnummer im internationalen Format verlangt, z. B. `+491701234567`.\n\n"
              + "Die Freigabe ist zeitlich befristet (meist 90 Tage); GiroCrab erinnert dich an die Erneuerung.",
          keywords: ["psd2", "c24", "n26", "enable banking", "pem", "privacy", "tos", "telefon", "phone", "open banking"] },
        { id: "other-banks", icon: "creditcard", title: "comdirect, Trade Republic, Scalable Capital, Amex",
          body: "- **comdirect:** Zugang über die comdirect-Schnittstelle; Zugangsdaten und die Freigabe per photoTAN/Push in der App bestätigen.\n"
              + "- **Trade Republic:** Anmeldung mit Telefonnummer und PIN, danach ein Bestätigungscode. Es werden Depot und Verrechnungskonto abgefragt.\n"
              + "- **Scalable Capital:** Anmeldung im Browserfenster von GiroCrab; Depot und Umsätze werden danach übernommen.\n"
              + "- **Amex / Amazon Visa:** Über das Portal-Fenster anmelden oder Umsätze als CSV/PDF importieren.\n\n"
              + "Alle Zugangsdaten bleiben lokal im verschlüsselten Tresor.",
          keywords: ["comdirect", "trade republic", "scalable", "amex", "american express", "amazon", "visa", "depot", "paypal"] },
        { id: "categories", icon: "tag", title: "Kategorien, Regeln & Suche",
          body: "**Kategorien** sind hierarchisch (Hauptkategorie › Unterkategorie). Neue legst du über *Ablage › Neue Hauptkategorie …* oder direkt im Kategorie-Dialog an. In der Buchungsliste öffnet **C** die schnelle Kategorieauswahl.\n\n"
              + "**Regeln** (*Konten › Regeln …*, Strg+Alt+K) ordnen Buchungen automatisch zu. Ein Ausdruck kombiniert Felder und Beträge:\n\n"
              + "- `name:REWE` – Name des Gegenübers\n- `purpose:\"Bahn AG\"` – Verwendungszweck\n- `remote_account:DE89…` – IBAN/Konto des Gegenübers\n"
              + "- `amount>100` oder `amount<0` – Betragsvergleich (auch `>=`, `<=`, `=`, `!=`)\n"
              + "- Verknüpfen mit `AND`, `OR`, `NOT` und Klammern; `*` und `?` als Platzhalter, `/Regex/` für reguläre Ausdrücke\n\n"
              + "Beispiel: `name:REWE OR purpose:\"Bahn AG\"`. Mit **R** in der Liste erzeugst du eine Regel direkt aus einer Buchung.\n\n"
              + "**Splitbuchungen:** Eine Buchung lässt sich auf mehrere Kategorien aufteilen (z. B. Supermarkt-Einkauf in Lebensmittel und Haushalt). Die Summe der Teile muss dem Betrag entsprechen.\n\n"
              + "**Interne Umbuchungen** zwischen eigenen Konten werden erkannt und zählen nicht als Einnahme oder Ausgabe.\n\n"
              + "**Suche:** Strg+F fokussiert das Suchfeld; es versteht dieselben Ausdrücke wie die Regeln.",
          keywords: ["regel", "rule", "kategorie", "category", "split", "umbuchung", "transfer", "suche", "search", "name:", "purpose:", "iban", "amount", "betrag", "regex"] },
        { id: "vault", icon: "lock.shield", title: "Tresor & Datenschutz",
          body: "**100 % lokal:** Alle Daten liegen in einer verschlüsselten SQLite/SQLCipher-Datenbank auf deinem Rechner. GiroCrab hat keinen eigenen Server und sendet nichts an Dritte; Abfragen gehen nur direkt an deine Bank bzw. den gewählten Dienst.\n\n"
              + "**Schlüssel:** Der Tresorschlüssel liegt im Schlüsselbund deiner Sitzung (Secret Service: KWallet oder GNOME Schlüsselbund). Beim Entsperren fragt der Schlüsselbund gegebenenfalls nach seinem Passwort.\n\n"
              + "**Tresor sperren:** *Ablage › Tresor sperren* (Strg+Meta+L) oder *Einstellungen › Sicherheit › Jetzt sperren*.\n\n"
              + "**Schlüssel sichern:** Unter *Einstellungen › Sicherheit › Tresor-Schlüssel* zeigst du den Schlüssel an (Base64) oder fügst ihn auf einem anderen Rechner wieder ein. Ohne Schlüssel lässt sich der Tresor nicht öffnen.",
          keywords: ["sqlcipher", "verschlüsselung", "encryption", "schlüsselbund", "keyring", "kwallet", "gnome", "secret service", "sperren", "lock", "datenschutz", "privacy", "schlüssel", "key"] }]

    /// HelpTopic.matches: all terms must occur (case and diacritics ignored).
    function matches(hay) {
        const terms = query.split(/\s+/).filter(t => t !== "")
        const h = Fmt.fold(hay)
        return terms.every(t => h.indexOf(Fmt.fold(t)) >= 0)
    }
    readonly property var visibleTopics: topics.filter(t => matches([t.title, t.body].concat(t.keywords).join(" ")))
    readonly property bool showShortcuts: matches(shortcuts.map(s => s.join(" ")).join(" ") + " Tastaturkürzel keyboard shortcuts")

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
                        SettingsFormRow { required property var modelData; label: modelData[1]; value: modelData[0] }
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
        spacing: 7
        SFIcon { symbol: lr.symbol; size: 14; color: Theme.accent }
        Text { text: lr.text; font.pixelSize: Theme.body; color: Theme.accent
               MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: Qt.openUrlExternally(lr.url) } }
    }
}
