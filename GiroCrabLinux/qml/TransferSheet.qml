import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// TransferSheetView.swift: "Neue Überweisung" – SEPA credit transfer via FinTS
// (HKCCS) or bunq. After the confirmation card the model starts the session;
// the bank's TAN request is shown by the existing TwoFactorSheet. Accounts
// GiroCrab cannot send from end with a GiroCode instead.
Sheet {
    id: sheet
    readonly property var draft: AppModel.transferDraft
    property bool confirming: false
    property var suggestions: []
    property string importNote: ""
    property var templates: []
    readonly property int maxPurpose: 140

    readonly property var account: AppModel.transferFormAccounts.find(a => a.id === draft.account_id) || null
    /// The account can send from GiroCrab (FinTS / bunq); otherwise the form ends with a GiroCode.
    readonly property bool canSend: account !== null && AppModel.canSendTransfer(account.id)
    /// The banking policy blocks this account's login (bankingGate(forAccount:)).
    readonly property bool gated: { void AppModel.bankingPolicy; return account !== null && AppModel.bankingGateForAccount(account.id) !== null }
    readonly property bool ibanValid: AppModel.validateIban(draft.iban)
    readonly property string bicText: draft.bic.trim()
    readonly property bool bicValid: bicText === "" || AppModel.looksLikeBIC(bicText)
    readonly property var cents: { const c = AppModel.parseCents(draft.amountText); return c !== null && c > 0 ? c : null }
    readonly property bool isBunq: account !== null && account.connector === "Bunq"
    readonly property bool offersInstant: account !== null && AppModel.offersInstantChoice(account.connector)
    readonly property bool sendsInstant: draft.instant && offersInstant
    readonly property bool isMagicDemoAccount: {
        if (!account) return false
        const c = AppModel.connections.find(x => x.id === account.connection_id)
        return c ? AppModel.isMagicDemoLogin(c.login_name) : false
    }
    readonly property bool pinStored: {
        if (!account || account.connection_id === null) return false
        if (AppModel.isDemo) return true
        const st = AppModel.connectionStatus(account.connection_id)
        return st ? st.has_pin : false
    }
    readonly property string giroCodePayload: cents === null ? "" : (GiroCode.payload(draft.name, draft.iban, bicText, cents, draft.purpose) || "")
    readonly property bool canReview: account !== null && draft.name.trim() !== "" && ibanValid && bicValid && cents !== null
                                      && draft.purpose.length <= maxPurpose
    readonly property string accountLabel: account ? account.name + " · " + Fmt.iban(account.iban) : "–"

    visible: AppModel.showTransferSheet
    sheetWidth: 520
    closePolicy: AppModel.transferBusy ? Popup.NoAutoClose : Popup.CloseOnEscape
    onAboutToShow: {
        confirming = false
        importNote = ""
        suggestions = []
        templates = AppModel.transferTemplates()
    }
    onClosed: AppModel.showTransferSheet = false

    function close_() { AppModel.showTransferSheet = false }
    function pasteFromClipboard() { report(PaymentParser.parseText(AppModel.clipboardText())) }
    function importInvoice(url) {
        importNote = qsTr("Lese Rechnung …")
        const path = decodeURIComponent(url.toString().replace(/^file:\/\//, ""))
        // read off the GUI thread (large PDFs); a closed sheet drops the late answer
        PaymentParser.parseFile(path, p => { if (sheet.visible && !sheet.confirming) sheet.report(p || {}) })
    }
    function report(p) {
        if (PaymentParser.isEmpty(p)) { importNote = qsTr("Nichts Erkennbares gefunden"); return }
        AppModel.setDraft(PaymentParser.patch(p))
        importNote = qsTr("Felder ausgefüllt – bitte prüfen")
    }
    function refreshSuggestions() { suggestions = nameField.activeFocus ? AppModel.suggestRecipients(draft.name) : [] }

    // ⇧Strg+V; Strg+V outside a text field (inside one, normal paste keeps working).
    Shortcut { sequences: ["Ctrl+Shift+V", StandardKey.Paste]; enabled: sheet.visible && !sheet.confirming; onActivated: sheet.pasteFromClipboard() }

    ColumnLayout {
        width: sheet.availableWidth
        spacing: 16
        RowLayout {
            spacing: 10
            SFIcon { symbol: "paperplane.circle.fill"; size: 26; color: Theme.accent }
            Text {
                text: sheet.confirming ? (sheet.canSend ? qsTr("Überweisung prüfen") : qsTr("GiroCode scannen")) : qsTr("Neue Überweisung")
                font.pixelSize: Theme.title2 + 2; font.weight: Font.Bold; color: Theme.text
            }
            Item { Layout.fillWidth: true }
        }

        // MARK: form
        ColumnLayout {
            visible: !sheet.confirming
            Layout.fillWidth: true
            spacing: 12
            RowLayout {
                Layout.alignment: Qt.AlignRight
                spacing: 10
                Button {
                    icon.name: SF.icon("doc.on.clipboard"); text: qsTr("Aus Zwischenablage einfügen")
                    onClicked: sheet.pasteFromClipboard()
                    ToolTip.text: qsTr("Erkennt IBAN, Betrag, Empfänger und Zweck (⇧Strg+V; Strg+V außerhalb von Textfeldern). Rechnung (PDF, ZUGFeRD) hierher ziehen.")
                    ToolTip.visible: hovered; ToolTip.delay: 600
                }
                Text { text: sheet.importNote || qsTr("Oder Rechnung hierher ziehen"); font.pixelSize: Theme.caption; color: Theme.tertiary; elide: Text.ElideRight }
            }
            // TransferTemplatesMenu (PlanningUI.swift)
            Button {
                id: templatesButton
                Layout.alignment: Qt.AlignRight
                flat: true; icon.name: SF.icon("doc.on.doc"); text: qsTr("Vorlagen")
                onClicked: templatesMenu.popup(templatesButton, 0, templatesButton.height)
            }
            Field {
                label: qsTr("Von Konto")
                AppComboBox {
                    Layout.fillWidth: true
                    model: AppModel.transferFormAccounts.map(a => a.name + " · " + Fmt.iban(a.iban))
                    currentIndex: AppModel.transferFormAccounts.findIndex(a => a.id === sheet.draft.account_id)
                    onActivated: i => AppModel.setDraft({ account_id: AppModel.transferFormAccounts[i].id })
                }
            }
            Hint {
                visible: sheet.account !== null && !sheet.canSend && sheet.gated
                symbol: "exclamationmark.shield"
                // Security lock: no direct transfer, the GiroCode needs no bank contact.
                text: qsTr("Die Sicherheitssperre verhindert direkte Überweisungen von diesem Konto. Am Ende erhalten Sie einen GiroCode zum Scannen in der App Ihrer Bank.")
            }
            Hint {
                visible: sheet.account !== null && !sheet.canSend && !sheet.gated && sheet.account.connector === "Comdirect"
                symbol: "qrcode"
                // The comdirect REST API has no payment endpoint; FinTS has.
                text: qsTr("Die comdirect-Schnittstelle (REST) kann keine Überweisungen ausführen. Verbinden Sie das Konto zusätzlich per FinTS, um direkt zu überweisen. Sonst erhalten Sie am Ende einen GiroCode zum Scannen in der comdirect-App.")
            }
            Hint {
                visible: sheet.account !== null && !sheet.canSend && !sheet.gated && sheet.account.connector !== "Comdirect"
                symbol: "qrcode"
                text: qsTr("Von diesem Konto kann GiroCrab nicht direkt überweisen. Am Ende erhalten Sie einen GiroCode zum Scannen in der App Ihrer Bank.")
            }
            Field {
                label: qsTr("Empfänger")
                TextField {
                    id: nameField
                    Layout.fillWidth: true
                    placeholderText: qsTr("Name des Empfängers")
                    text: sheet.draft.name
                    onTextEdited: { AppModel.setDraft({ name: text }); sheet.refreshSuggestions() }
                    onActiveFocusChanged: sheet.refreshSuggestions()
                }
                Flickable {
                    visible: sheet.suggestions.length > 0
                    Layout.fillWidth: true
                    implicitHeight: chips.implicitHeight
                    contentWidth: chips.implicitWidth
                    clip: true
                    flickableDirection: Flickable.HorizontalFlick
                    Row {
                        id: chips
                        spacing: 6
                        Repeater {
                            model: sheet.suggestions
                            delegate: Rectangle {
                                required property var modelData
                                width: chip.implicitWidth + 16; height: chip.implicitHeight + 8
                                radius: 7; color: Theme.selection
                                Column {
                                    id: chip
                                    x: 8; y: 4
                                    Text { text: modelData.name; font.pixelSize: Theme.callout; color: Theme.text; elide: Text.ElideRight; width: Math.min(implicitWidth, 180) }
                                    Text { text: Fmt.iban(modelData.iban); font.pixelSize: Theme.caption2; font.family: "monospace"; color: Theme.secondary }
                                }
                                MouseArea {
                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: { AppModel.setDraft({ name: modelData.name, iban: AppModel.groupedIBAN(modelData.iban) }); sheet.suggestions = [] }
                                }
                            }
                        }
                    }
                }
            }
            Field {
                label: qsTr("IBAN")
                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    TextField {
                        Layout.fillWidth: true
                        placeholderText: "DE00 0000 0000 0000 0000 00"
                        font.family: "monospace"
                        inputMethodHints: Qt.ImhNoPredictiveText | Qt.ImhPreferUppercase
                        text: sheet.draft.iban
                        onTextEdited: AppModel.setDraft({ iban: AppModel.groupedIBAN(text) })
                    }
                    ValidMark { visible: sheet.draft.iban !== ""; ok: sheet.ibanValid
                                ToolTip.text: sheet.ibanValid ? qsTr("Prüfsumme korrekt") : qsTr("IBAN ungültig (Prüfsumme/Länge)") }
                }
            }
            Field {
                label: qsTr("BIC (optional)")
                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    TextField {
                        Layout.fillWidth: true
                        placeholderText: qsTr("z. B. GENODEF1KS2")
                        font.family: "monospace"
                        inputMethodHints: Qt.ImhNoPredictiveText
                        text: sheet.draft.bic
                        onTextEdited: AppModel.setDraft({ bic: text })
                    }
                    ValidMark { visible: sheet.bicText !== ""; ok: sheet.bicValid }
                }
            }
            Field {
                label: qsTr("Betrag")
                RowLayout {
                    spacing: 6
                    TextField {
                        Layout.preferredWidth: 160
                        placeholderText: Fmt.plain(0)
                        horizontalAlignment: TextInput.AlignRight
                        text: sheet.draft.amountText
                        onTextEdited: AppModel.setDraft({ amountText: text })
                    }
                    Text { text: "€"; color: Theme.secondary; font.pixelSize: Theme.body }
                    Text { visible: sheet.draft.amountText !== "" && sheet.cents === null; text: qsTr("Betrag > 0 eingeben"); font.pixelSize: Theme.caption; color: Theme.negative }
                }
            }
            Field {
                label: qsTr("Verwendungszweck")
                TextArea {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.max(implicitHeight, 52)
                    placeholderText: qsTr("Verwendungszweck")
                    wrapMode: TextEdit.Wrap
                    text: sheet.draft.purpose
                    onTextChanged: if (text !== sheet.draft.purpose) AppModel.setDraft({ purpose: text.slice(0, sheet.maxPurpose) })
                }
                Text {
                    Layout.alignment: Qt.AlignRight
                    text: sheet.draft.purpose.length + "/" + sheet.maxPurpose
                    font.pixelSize: Theme.caption
                    color: sheet.draft.purpose.length >= sheet.maxPurpose ? Theme.negative : Theme.tertiary
                }
            }
            Field {
                visible: sheet.canSend && sheet.offersInstant
                label: qsTr("Ausführung")
                CheckBox {
                    text: qsTr("Echtzeitüberweisung (SEPA Instant)")
                    checked: sheet.draft.instant
                    onToggled: AppModel.setDraft(checked ? { instant: true, scheduled: false } : { instant: false })
                }
                Text {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption; color: Theme.secondary
                    text: qsTr("Kommt in Sekunden an und ist nicht rückholbar. Bietet die Bank sie nicht an, wird nichts gesendet; Sie können sie dann als normale Überweisung senden.")
                }
                RowLayout {
                    visible: sheet.draft.instant && sheet.cents !== null && sheet.cents >= 10000000
                    Layout.fillWidth: true; spacing: 6
                    SFIcon { symbol: "exclamationmark.triangle"; size: 12; color: Theme.warning; Layout.alignment: Qt.AlignTop }
                    Text {
                        Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption; color: Theme.warning
                        text: qsTr("Viele Banken begrenzen Echtzeitüberweisungen (oft auf 100.000 € oder ein eigenes Limit). Die Bank kann den Auftrag dann ablehnen.")
                    }
                }
                CheckBox {
                    text: qsTr("Terminüberweisung")
                    enabled: !sheet.draft.instant
                    checked: sheet.draft.scheduled
                    onToggled: AppModel.setDraft({ scheduled: checked })
                }
                RowLayout {
                    visible: sheet.draft.scheduled && !sheet.draft.instant
                    spacing: 8
                    Text { text: qsTr("Ausführungsdatum"); color: Theme.text; font.pixelSize: Theme.body }
                    // DatePicker(in: tomorrow...): dd.MM.yyyy, earlier dates fall back to tomorrow.
                    TextField {
                        id: dateField
                        Layout.preferredWidth: 120
                        text: Fmt.medium(sheet.draft.executionDate)
                        validator: RegularExpressionValidator { regularExpression: /\d{1,2}\.\d{1,2}\.\d{4}/ }
                        // A date that does not exist (31.04.) keeps the previous one;
                        // leaving the field always shows the date in use again.
                        function commit() {
                            const p = text.split(".").map(Number)
                            const d = new Date(p[2], p[1] - 1, p[0])
                            const exists = p.length === 3 && !isNaN(d) && d.getFullYear() === p[2] && d.getMonth() === p[1] - 1 && d.getDate() === p[0]
                            if (exists) {
                                const t = new Date(); t.setHours(0, 0, 0, 0); t.setDate(t.getDate() + 1)
                                AppModel.setDraft({ executionDate: Fmt.iso(d < t ? t : d) })
                            }
                            text = Qt.binding(() => Fmt.medium(sheet.draft.executionDate))
                        }
                        onEditingFinished: commit()
                        onActiveFocusChanged: if (!activeFocus) commit()
                    }
                }
            }
            DemoHintBanner {
                visible: sheet.canSend && (AppModel.isDemo || sheet.isMagicDemoAccount)
                Layout.fillWidth: true
                credentials: false
                buttonTitle: qsTr("PIN 12345 einfügen")
                onFill: AppModel.setDraft({ pin: "12345" })
            }
            Field {
                visible: sheet.canSend && !sheet.pinStored
                label: sheet.isBunq ? qsTr("bunq-API-Schlüssel") : qsTr("Banking-PIN")
                TextField {
                    Layout.fillWidth: true
                    echoMode: TextInput.Password
                    placeholderText: sheet.isBunq ? qsTr("API-Schlüssel (wird nicht gespeichert)") : qsTr("PIN (wird nicht gespeichert)")
                    text: sheet.draft.pin
                    onTextEdited: AppModel.setDraft({ pin: text })
                }
            }
        }

        // MARK: confirmation (send)
        ColumnLayout {
            visible: sheet.confirming && sheet.canSend
            Layout.fillWidth: true
            spacing: 14
            Card {
                Layout.fillWidth: true
                ColumnLayout {
                    width: parent.width
                    spacing: 10
                    BigAmount {}
                    SummaryRow { key: qsTr("An"); value: sheet.draft.name }
                    SummaryRow { key: qsTr("IBAN"); value: sheet.draft.iban }
                    SummaryRow { visible: sheet.bicText !== ""; key: qsTr("BIC"); value: sheet.bicText.toUpperCase() }
                    SummaryRow { key: qsTr("Zweck"); value: sheet.draft.purpose === "" ? "–" : sheet.draft.purpose }
                    Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }
                    SummaryRow { key: qsTr("Von"); value: sheet.accountLabel }
                    SummaryRow {
                        key: qsTr("Ausführung")
                        value: {
                            if (sheet.sendsInstant) return qsTr("Sofort (Echtzeitüberweisung)")
                            const iso = AppModel.executionDateISO(sheet.draft)
                            return iso ? qsTr("Am %1 (Terminüberweisung)").arg(iso) : qsTr("Heute (SEPA-Überweisung)")
                        }
                    }
                }
            }
            Hint {
                indent: false; symbol: "exclamationmark.shield"; size: Theme.callout + 1
                text: qsTr("Bitte Empfänger und IBAN genau prüfen. Eine freigegebene Überweisung lässt sich meist nicht mehr zurückholen.")
            }
        }

        // MARK: confirmation (GiroCode) – read-only account (e.g. C24)
        ColumnLayout {
            visible: sheet.confirming && !sheet.canSend
            Layout.fillWidth: true
            spacing: 14
            Card {
                Layout.fillWidth: true
                RowLayout {
                    width: parent.width
                    spacing: 16
                    GiroCodeImage {
                        Layout.preferredWidth: 200; Layout.preferredHeight: 200; Layout.alignment: Qt.AlignTop
                        payload: sheet.confirming ? sheet.giroCodePayload : ""
                    }
                    ColumnLayout {
                        Layout.fillWidth: true; Layout.alignment: Qt.AlignTop
                        spacing: 8
                        BigAmount {}
                        SummaryRow { key: qsTr("An"); value: sheet.draft.name }
                        SummaryRow { key: qsTr("IBAN"); value: sheet.draft.iban }
                        SummaryRow { visible: sheet.bicText !== ""; key: qsTr("BIC"); value: sheet.bicText.toUpperCase() }
                        SummaryRow { key: qsTr("Zweck"); value: sheet.draft.purpose === "" ? "–" : sheet.draft.purpose }
                        SummaryRow { key: qsTr("Von"); value: sheet.accountLabel }
                    }
                }
            }
            Hint {
                indent: false; symbol: "camera.viewfinder"; size: Theme.callout + 1
                text: qsTr("In der App Ihrer Bank „Fotoüberweisung“ bzw. „QR-Code scannen“ wählen, den Code scannen und dort mit TAN freigeben. GiroCrab sendet nichts.")
            }
        }

        RowLayout {
            visible: AppModel.transferError !== ""
            Layout.fillWidth: true; spacing: 6
            SFIcon { symbol: "exclamationmark.triangle.fill"; size: 14; color: Theme.negative; Layout.alignment: Qt.AlignTop }
            TextEdit { Layout.fillWidth: true; readOnly: true; selectByMouse: true; wrapMode: Text.WordWrap
                       text: AppModel.transferError; color: Theme.negative; font.pixelSize: Theme.callout + 1 }
        }

        // Instant was not possible and nothing was sent: offer a regular
        // transfer, which needs its own approval.
        Rectangle {
            visible: AppModel.transferInstantDeclined !== null
            Layout.fillWidth: true
            implicitHeight: declined.implicitHeight + 24
            radius: 8
            color: Theme.withAlpha(Theme.warning, 0.1)
            ColumnLayout {
                id: declined
                x: 12; y: 12; width: parent.width - 24
                spacing: 8
                RowLayout { spacing: 6
                    SFIcon { symbol: "bolt.slash.fill"; size: 14; color: Theme.text }
                    Text { text: qsTr("Echtzeitüberweisung nicht ausgeführt"); font.pixelSize: Theme.callout + 1; font.weight: Font.Bold; color: Theme.text } }
                Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.callout + 1; color: Theme.text
                       text: qsTr("Es wurde kein Geld gesendet. Grund der Bank: %1").arg(AppModel.transferInstantDeclined || "") }
                Button { text: qsTr("Als normale Überweisung senden"); enabled: !AppModel.transferBusy; onClicked: AppModel.sendAsRegularTransfer() }
                Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption; color: Theme.secondary
                       text: qsTr("Kommt in der Regel am nächsten Bankarbeitstag an. Sie geben sie erneut frei.") }
            }
        }

        // MARK: buttons
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Button { visible: !(sheet.confirming && !sheet.canSend); text: qsTr("Abbrechen"); onClicked: sheet.close_() }
            Button { visible: sheet.confirming && !sheet.canSend; text: qsTr("Zurück"); onClicked: sheet.confirming = false }
            Item { Layout.fillWidth: true }
            Button { visible: sheet.confirming && sheet.canSend; text: qsTr("Zurück"); onClicked: sheet.confirming = false }
            Button {
                visible: sheet.confirming && !sheet.canSend
                text: qsTr("Fertig"); highlighted: true
                onClicked: sheet.close_()
            }
            Button {
                visible: sheet.confirming && sheet.canSend
                text: sheet.isBunq ? qsTr("In der bunq-App freigeben") : qsTr("Jetzt mit TAN freigeben")
                highlighted: true
                enabled: !AppModel.transferBusy
                onClicked: AppModel.startTransfer()
            }
            Button {
                id: nextButton
                visible: !sheet.confirming
                text: sheet.canSend ? qsTr("Weiter") : qsTr("GiroCode erstellen")
                highlighted: true
                enabled: sheet.canReview && !(sheet.canSend && !sheet.pinStored && sheet.draft.pin === "")
                         && !(!sheet.canSend && sheet.giroCodePayload === "")
                onClicked: { AppModel.transferError = ""; sheet.confirming = true }
            }
        }
    }

    // .keyboardShortcut(.defaultAction)
    Shortcut {
        sequences: ["Return", "Enter"]
        enabled: sheet.visible && !templateName.visible && !deleteConfirm.visible
        onActivated: {
            if (!sheet.confirming) { if (nextButton.enabled) nextButton.clicked() }
            else if (!sheet.canSend) sheet.close_()
            else if (!AppModel.transferBusy) AppModel.startTransfer()
        }
    }

    // Rechnung (PDF, ZUGFeRD-XML) hierher ziehen.
    DropArea {
        parent: sheet.contentItem
        anchors.fill: parent
        enabled: !sheet.confirming
        onDropped: drop => { if (drop.hasUrls) sheet.importInvoice(drop.urls[0]) }
        Rectangle {
            anchors.fill: parent; anchors.margins: -8
            visible: parent.containsDrag
            radius: 12; color: Theme.withAlpha(Theme.accent, 0.06)
            border.color: Theme.accent; border.width: 2
        }
    }

    AppMenu {
        id: templatesMenu
        // `if !templates.isEmpty { Menu("Vorlage löschen") }`: the submenu's entry
        // is hidden while there are no templates.
        onAboutToShow: {
            for (let i = 0; i < count; ++i) {
                const item = itemAt(i)
                if (item && item.subMenu === deleteMenu) {
                    item.visible = sheet.templates.length > 0
                    item.height = item.visible ? item.implicitHeight : 0
                }
            }
        }
        Instantiator {
            model: sheet.templates
            delegate: AppMenuItem {
                required property var modelData
                text: modelData.name + " · " + modelData.recipient_name
                onTriggered: AppModel.applyTransferTemplate(modelData)
            }
            onObjectAdded: (i, o) => templatesMenu.insertItem(i, o)
            onObjectRemoved: (i, o) => templatesMenu.removeItem(o)
        }
        AppMenuSeparator { visible: sheet.templates.length > 0; height: visible ? implicitHeight : 0 }
        AppMenu {
            id: deleteMenu
            title: qsTr("Vorlage löschen")
            enabled: sheet.templates.length > 0
            Instantiator {
                model: sheet.templates
                delegate: AppMenuItem {
                    required property var modelData
                    text: modelData.name + " …"
                    onTriggered: { deleteConfirm.template = modelData; deleteConfirm.open() }
                }
                onObjectAdded: (i, o) => deleteMenu.insertItem(i, o)
                onObjectRemoved: (i, o) => deleteMenu.removeItem(o)
            }
        }
        AppMenuItem {
            text: qsTr("Als Vorlage speichern …"); icon.name: SF.icon("square.and.arrow.down")
            enabled: sheet.draft.name.trim() !== "" && sheet.draft.iban !== ""
            onTriggered: { templateNameField.text = sheet.draft.name; templateName.open() }
        }
    }

    // .alert("Vorlage speichern") { TextField("Name der Vorlage") }
    Sheet {
        id: templateName
        sheetWidth: 340
        ColumnLayout {
            width: templateName.availableWidth
            spacing: 12
            Text { text: qsTr("Vorlage speichern"); font.pixelSize: Theme.body + 2; font.weight: Font.Bold; color: Theme.text }
            TextField { id: templateNameField; Layout.fillWidth: true; placeholderText: qsTr("Name der Vorlage"); onAccepted: saveButton.clicked() }
            RowLayout {
                Item { Layout.fillWidth: true }
                Button { text: qsTr("Abbrechen"); onClicked: templateName.close() }
                Button {
                    id: saveButton
                    text: qsTr("Speichern"); highlighted: true
                    onClicked: { AppModel.saveTransferTemplate(templateNameField.text); sheet.templates = AppModel.transferTemplates(); templateName.close() }
                }
            }
        }
    }

    // .confirmationDialog("Vorlage „…“ löschen?")
    Sheet {
        id: deleteConfirm
        property var template: null
        sheetWidth: 340
        ColumnLayout {
            width: deleteConfirm.availableWidth
            spacing: 12
            Text { Layout.fillWidth: true; wrapMode: Text.WordWrap
                   text: qsTr("Vorlage „%1“ löschen?").arg(deleteConfirm.template ? deleteConfirm.template.name : "")
                   font.pixelSize: Theme.body + 2; font.weight: Font.Bold; color: Theme.text }
            RowLayout {
                Item { Layout.fillWidth: true }
                Button { text: qsTr("Abbrechen"); onClicked: deleteConfirm.close() }
                Button {
                    text: qsTr("Löschen")
                    palette.buttonText: Theme.negative
                    onClicked: { AppModel.deleteTransferTemplate(deleteConfirm.template.id); sheet.templates = AppModel.transferTemplates(); deleteConfirm.close() }
                }
            }
        }
    }

    // field(_:content:): right-aligned label column of 140 pt.
    component Field: RowLayout {
        property string label
        default property alias content: holder.data
        Layout.fillWidth: true
        spacing: 12
        Text { Layout.preferredWidth: 140; Layout.alignment: Qt.AlignTop; Layout.topMargin: 6; horizontalAlignment: Text.AlignRight
               text: parent.label; color: Theme.secondary; font.pixelSize: Theme.body; wrapMode: Text.WordWrap }
        ColumnLayout { id: holder; Layout.fillWidth: true; spacing: 6 }
    }
    component Hint: RowLayout {
        property alias text: hintText.text
        property alias symbol: hintIcon.symbol
        property bool indent: true
        property int size: Theme.caption
        Layout.fillWidth: true
        Layout.leftMargin: indent ? 152 : 0
        spacing: 6
        SFIcon { id: hintIcon; size: 14; Layout.alignment: Qt.AlignTop; color: Theme.secondary }
        Text { id: hintText; Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: parent.size; color: Theme.secondary }
    }
    component SummaryRow: RowLayout {
        property string key
        property string value
        Layout.fillWidth: true
        spacing: 8
        Text { Layout.preferredWidth: 90; Layout.alignment: Qt.AlignTop; text: parent.key; color: Theme.secondary; font.pixelSize: Theme.body }
        TextEdit { Layout.fillWidth: true; readOnly: true; selectByMouse: true; wrapMode: Text.WordWrap; text: parent.value; color: Theme.text; font.pixelSize: Theme.body }
    }
    component BigAmount: Text {
        text: Fmt.money(sheet.cents === null ? 0 : sheet.cents).replace("−", "")
        font.pixelSize: Theme.largeTitle + 4; font.weight: Font.DemiBold; color: Theme.text
        font.features: { "tnum": 1 }
    }
    component ValidMark: SFIcon {
        property bool ok
        symbol: ok ? "checkmark.circle.fill" : "xmark.circle.fill"
        size: 16
        color: ok ? Theme.inflow : Theme.negative
        HoverHandler { id: hover }
        ToolTip.visible: hover.hovered && ToolTip.text !== ""
    }
}
