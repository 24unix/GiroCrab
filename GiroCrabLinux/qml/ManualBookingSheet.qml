import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// OfflineAccountsUI.swift › ManualBookingSheet (#679, #81): "Neue Buchung …" / "Buchung bearbeiten …"
// with date, amount, name, purpose, category and note. Driven by `OfflineAccounts.bookingRequest`;
// built only while open (Main.qml, Loader: the category list is long).
Sheet {
    id: sheet
    readonly property var request: OfflineAccounts.bookingRequest
    readonly property bool isNew: !request || request.booking === null
    visible: request !== null
    // macFrame(width: 460): wider here, the date field has three steppers instead of a compact picker
    sheetWidth: 580
    onClosed: OfflineAccounts.bookingRequest = null

    property var accountId: null
    property date date: new Date()
    /// Flow: "out" | "in"
    property string flow: "out"
    property string saveError: ""

    readonly property var accountChoices: OfflineAccounts.offlineAccounts
    readonly property var categoryOptions: [{ id: null, title: qsTr("Ohne Kategorie") }]
        .concat(AppModel.categories.map(c => ({ id: c.id, title: c.path })))
    property var categoryId: null

    /// The typed amount with its sign, null while it is not a usable number.
    readonly property var amountCents: {
        const cents = Fmt.parseCents(amountField.text)
        if (cents === null || cents === 0) return null
        const magnitude = Math.abs(cents)
        return flow === "out" ? -magnitude : magnitude
    }

    Component.onCompleted: load()
    function load() {
        const req = OfflineAccounts.bookingRequest
        if (!req) return
        accountId = req.accountId
        const b = req.booking
        if (b) {
            date = Fmt.date(b.booking_date) || new Date()
            flow = b.amount_cents < 0 ? "out" : "in"
            amountField.text = Fmt.plain(Math.abs(b.amount_cents))
            counterpartyField.text = b.counterparty
            purposeField.text = b.purpose
            categoryId = b.category_id
            noteField.text = b.note
        }
        Qt.callLater(() => amountField.forceActiveFocus())
    }

    function save() {
        const cents = amountCents
        if (cents === null) return
        const setup = {
            booking_date: Fmt.iso(date), amount_cents: cents,
            counterparty: counterpartyField.text, purpose: purposeField.text,
            category_id: categoryId, note: noteField.text
        }
        try {
            OfflineAccounts.saveManualBooking(accountId, request.booking ? request.booking.id : null, setup)
            close()
        } catch (e) {
            saveError = AppModel.parseCoreError(e.message).message
        }
    }

    ColumnLayout {
        width: sheet.availableWidth
        spacing: 14
        Text { text: sheet.isNew ? qsTr("Neue Buchung") : qsTr("Buchung bearbeiten")
               font.pixelSize: Theme.title3; font.weight: Font.Bold; color: Theme.text; Accessible.role: Accessible.Heading }
        GridLayout {
            Layout.fillWidth: true
            Layout.maximumWidth: sheet.availableWidth
            columns: 2
            columnSpacing: 12; rowSpacing: 8
            // the account picker only for a new booking and more than one offline account
            Text { visible: accountBox.visible; text: qsTr("Konto"); font.pixelSize: Theme.body; color: Theme.text; Layout.alignment: Qt.AlignRight }
            AppComboBox {
                id: accountBox
                visible: sheet.accountChoices.length > 1 && sheet.isNew
                Layout.fillWidth: true
                model: sheet.accountChoices
                textRole: "name"
                currentIndex: Math.max(0, sheet.accountChoices.findIndex(a => a.id === sheet.accountId))
                onActivated: i => sheet.accountId = sheet.accountChoices[i].id
                Sensitive {}
            }
            Text { text: qsTr("Datum"); font.pixelSize: Theme.body; color: Theme.text; Layout.alignment: Qt.AlignRight }
            DateField { date: sheet.date; onPicked: d => sheet.date = d }
            Text { text: qsTr("Art"); font.pixelSize: Theme.body; color: Theme.text; Layout.alignment: Qt.AlignRight }
            Segmented {
                Layout.fillWidth: true
                options: [{ id: "out", title: qsTr("Ausgabe") }, { id: "in", title: qsTr("Einnahme") }]
                current: sheet.flow
                onActivated: id => sheet.flow = id
            }
            Text { text: qsTr("Betrag"); font.pixelSize: Theme.body; color: Theme.text; Layout.alignment: Qt.AlignRight }
            TextField { id: amountField; Layout.fillWidth: true; horizontalAlignment: TextInput.AlignRight; font.features: { "tnum": 1 }
                        onAccepted: sheet.save(); Sensitive { amounts: true } }
            Text { text: qsTr("Name oder Empfänger"); font.pixelSize: Theme.body; color: Theme.text; Layout.alignment: Qt.AlignRight }
            TextField { id: counterpartyField; Layout.fillWidth: true; onAccepted: sheet.save(); Sensitive {} }
            Text { text: qsTr("Verwendungszweck"); font.pixelSize: Theme.body; color: Theme.text; Layout.alignment: Qt.AlignRight }
            TextField { id: purposeField; Layout.fillWidth: true; onAccepted: sheet.save(); Sensitive {} }
            Text { text: qsTr("Kategorie"); font.pixelSize: Theme.body; color: Theme.text; Layout.alignment: Qt.AlignRight }
            AppComboBox {
                Layout.fillWidth: true
                model: sheet.categoryOptions
                textRole: "title"
                currentIndex: Math.max(0, sheet.categoryOptions.findIndex(o => o.id === sheet.categoryId))
                onActivated: i => sheet.categoryId = sheet.categoryOptions[i].id
                Sensitive { labels: true }
            }
            Text { text: qsTr("Notiz"); font.pixelSize: Theme.body; color: Theme.text; Layout.alignment: Qt.AlignRight | Qt.AlignTop; Layout.topMargin: 6 }
            // TextField(axis: .vertical).lineLimit(1...4)
            ScrollView {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(Math.max(noteField.implicitHeight, 32), 4 * Theme.body * 1.5 + 16)
                ScrollBar.vertical: ScrollViewBar {}
                TextArea { id: noteField; wrapMode: TextEdit.Wrap; font.pixelSize: Theme.body; Sensitive {} }
            }
        }
        Text { visible: sheet.saveError !== ""; text: sheet.saveError; font.pixelSize: Theme.caption; color: Theme.negative
               wrapMode: Text.WordWrap; Layout.fillWidth: true }
        RowLayout {
            Layout.fillWidth: true
            Item { Layout.fillWidth: true }
            Button { text: qsTr("Abbrechen"); onClicked: sheet.close() }
            Button { text: qsTr("Sichern"); highlighted: true; enabled: sheet.amountCents !== null; onClicked: sheet.save() }
        }
    }
}
