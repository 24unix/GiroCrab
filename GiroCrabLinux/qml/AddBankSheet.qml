import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// AddBankAssistant.swift › AddBankSheet: bank → access → (setup) → add + first sync.
// FinTsAddForm.swift, BankPicker.swift (KindAddForm, Psd2AddForm) are inline below.
Sheet {
    id: sheet
    sheetWidth: 860
    property string step: "bank"          // bank | access | setup
    property string query: ""
    property var selected: null           // BankSearchResult
    property var ways: []
    property var setupValues: ({})
    property var popular: []
    readonly property var manualFinTs: ({ id: "fints:custom", name: "", mode: "FinTs", country: "DE", blz: "", url: "", connector: null, aspsp: "", tested: "" })
    readonly property var popularNames: ["ING", "DKB", "comdirect", "Postbank", "Consorsbank", "N26", "C24", "Revolut", "bunq", "Trade Republic", "Scalable Capital", "PayPal"]
    readonly property var modeOrder: ["FinTs", "OwnApi", "Psd2"]

    function search(q, limit) { return AppModel.core("search_banks", { query: q, live_psd2: [], per_group_limit: limit || 12 }) }
    readonly property bool searching: query.trim() !== ""
    readonly property var results: searching ? search(query) : []
    function key(s) { return s.toLowerCase().replace(/[^\p{L}\p{N}]/gu, "") }
    function loadPopular() {
        popular = popularNames.map(name => {
            const k = key(name)
            const hits = search(name, 3).filter(r => key(r.name).startsWith(k))
            hits.sort((a, b) => modeOrder.indexOf(a.mode) - modeOrder.indexOf(b.mode))
            return hits[0]
        }).filter(x => x)
    }
    /// AddBankSheet.ways(to:in:): the same bank by the other access modes.
    function waysTo(r) {
        const all = search(r.name)
        const k = key(r.name)
        if (k.length < 3) return [r]
        const out = [r]
        for (const m of modeOrder) {
            if (m === r.mode) continue
            const other = all.find(x => { const o = key(x.name); return x.mode === m && o.length >= 3 && (o.startsWith(k) || k.startsWith(o)) })
            if (other) out.push(other)
        }
        out.sort((a, b) => modeOrder.indexOf(a.mode) - modeOrder.indexOf(b.mode))
        return out
    }
    function groupTitle(m) { return m === "FinTs" ? qsTr("Direkt (FinTS 3.0 / HBCI)") : m === "OwnApi" ? qsTr("Direkt (Eigene API)") : qsTr("PSD2 (via Enable Banking)") }
    function groupHint(m) { return m === "FinTs" ? qsTr("Keine Registrierung bei Dritten nötig") : m === "OwnApi" ? qsTr("Direkter Zugang über die API der Bank")
                                                 : qsTr("Benötigt eine kostenlose eigene Enable-Banking-Anwendung") }
    function symbolOf(r) {
        if (r.connector) { const d = AppModel.descriptor(r.connector); if (d) return d.sf_symbol }
        return r.mode === "Psd2" ? "building.columns.circle" : "building.columns"
    }
    function detailLine(r) {
        if (r.mode === "FinTs") return qsTr("BLZ %1").arg(r.blz)
        if (r.mode === "Psd2") return r.country
        return ""
    }
    readonly property var missingSettings: {
        if (!selected) return []
        const kind = selected.connector || (selected.mode === "FinTs" ? "FinTsGeneric" : "EnableBanking")
        const d = AppModel.descriptor(kind)
        if (!d) return []
        return d.required_settings.filter(k => { const e = AppModel.settingEntry(k); return !(e && e.has_value) && !(k === "fints.product_id" && AppModel.fintsProductIDSource !== "") })
    }
    readonly property bool isLastStep: step === "setup" || (step === "access" && missingSettings.length === 0)
    readonly property bool canContinue: step === "bank" ? selected !== null
        : step === "access" ? (formLoader.item ? formLoader.item.canAdd : false)
        : missingSettings.every(k => (setupValues[k] || "").trim() !== "")
    function next() {
        if (!canContinue) return
        if (step === "bank") {
            ways = selected.id === manualFinTs.id ? [selected] : waysTo(selected)
            step = "access"
        } else if (step === "access") {
            if (missingSettings.length === 0) commit(); else step = "setup"
        } else {
            for (const k in setupValues) if ((setupValues[k] || "").trim() !== "") AppModel.saveSetting(k, setupValues[k])
            commit()
        }
    }
    function commit() { formLoader.item.commit(); close() }
    function back() { step = step === "setup" ? "access" : "bank" }

    onAboutToShow: { step = "bank"; query = ""; searchField.text = ""; selected = null; setupValues = ({}); loadPopular(); searchField.forceActiveFocus() }

    ColumnLayout {
        width: sheet.availableWidth
        spacing: 16
        // ImportAssistantHeader
        RowLayout {
            spacing: 12
            SFIcon { symbol: "building.columns"; size: 26; color: Theme.accent; Layout.alignment: Qt.AlignTop }
            ColumnLayout { spacing: 3; Layout.fillWidth: true
                Text { font.pixelSize: Theme.title3 + 2; font.weight: Font.DemiBold; color: Theme.text
                       text: sheet.step === "bank" ? qsTr("Bank hinzufügen") : sheet.step === "setup" ? qsTr("Einrichten")
                           : (sheet.selected && sheet.selected.id === sheet.manualFinTs.id ? qsTr("Andere FinTS-Bank") : (sheet.selected ? sheet.selected.name : "")) }
                Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.callout + 1; color: Theme.secondary
                       text: sheet.step === "bank" ? qsTr("Suchen Sie Ihre Bank nach Name, Bankleitzahl oder IBAN.")
                           : sheet.step === "access" ? qsTr("Wie GiroCrab die Umsätze abruft. PIN und TAN fragt GiroCrab erst beim ersten Abruf ab.")
                           : qsTr("Diese Angaben braucht GiroCrab einmalig, danach gelten sie für alle Banken dieser Art.") }
            }
        }

        StackLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(470, sheet.maxBodyHeight - 150)
            currentIndex: sheet.step === "bank" ? 0 : sheet.step === "access" ? 1 : 2

            // bankStep
            ColumnLayout {
                spacing: 10
                TextField {
                    id: searchField
                    Layout.fillWidth: true
                    placeholderText: qsTr("Bank, BLZ oder IBAN suchen …")
                    leftPadding: 28
                    onTextChanged: { sheet.query = text; sheet.selected = null }
                    SFIcon { symbol: "magnifyingglass"; size: 14; anchors.verticalCenter: parent.verticalCenter; x: 8 }
                }
                ListView {
                    id: bankList
                    Layout.fillWidth: true; Layout.fillHeight: true
                    clip: true
                    ScrollBar.vertical: AppScrollBar {}
                    model: {
                        const rows = []
                        if (!sheet.searching) {
                            rows.push({ header: qsTr("Beliebte Banken") })
                            for (const r of sheet.popular) rows.push({ bank: r })
                            rows.push({ footer: qsTr("Jede Sparkasse und Volksbank ist eine eigene Bank. Suchen Sie sie über ihren Namen (meist mit Ort), die Bankleitzahl oder Ihre IBAN.") })
                        } else if (!sheet.results.length) {
                            rows.push({ footer: qsTr("Keine Ergebnisse für „%1“").arg(sheet.query) })
                        } else {
                            for (const m of sheet.modeOrder) {
                                const rs = sheet.results.filter(r => r.mode === m)
                                if (!rs.length) continue
                                rows.push({ header: sheet.groupTitle(m), hint: sheet.groupHint(m) })
                                for (const r of rs) rows.push({ bank: r })
                            }
                        }
                        rows.push({ header: qsTr("Nicht gefunden?") })
                        rows.push({ bank: sheet.manualFinTs, manual: true })
                        return rows
                    }
                    delegate: Item {
                        required property var modelData
                        width: ListView.view.width
                        height: modelData.bank ? 44 : modelData.header ? (modelData.hint ? 44 : 30) : footerText.implicitHeight + 10
                        ColumnLayout {
                            visible: !!modelData.header
                            anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.leftMargin: 8; anchors.bottomMargin: 4
                            spacing: 1
                            Text { text: modelData.header || ""; font.pixelSize: Theme.callout; font.weight: Font.DemiBold; color: Theme.secondary }
                            Text { visible: !!modelData.hint; text: modelData.hint || ""; font.pixelSize: Theme.caption; color: Theme.secondary }
                        }
                        Text { id: footerText; visible: !!modelData.footer; text: modelData.footer || ""; width: parent.width - 16; x: 8; y: 4
                               wrapMode: Text.WordWrap; font.pixelSize: Theme.caption; color: Theme.secondary }
                        Rectangle {
                            visible: !!modelData.bank
                            anchors.fill: parent; anchors.margins: 1
                            radius: 6
                            color: sheet.selected && modelData.bank && sheet.selected.id === modelData.bank.id ? Theme.selection : "transparent"
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 10; spacing: 10
                                SFIcon { symbol: modelData.manual ? "square.and.pencil" : (modelData.bank ? sheet.symbolOf(modelData.bank) : ""); size: 18; Layout.preferredWidth: 22 }
                                ColumnLayout { spacing: 1; Layout.fillWidth: true
                                    Text { text: modelData.manual ? qsTr("Andere FinTS-Bank") : (modelData.bank ? modelData.bank.name : ""); font.pixelSize: Theme.body + 1; color: Theme.text
                                           Layout.fillWidth: true; elide: Text.ElideRight }
                                    Text { text: modelData.manual ? qsTr("Bankleitzahl und FinTS-Adresse selbst eingeben") : (modelData.bank ? sheet.detailLine(modelData.bank) : "")
                                           visible: text !== ""; font.pixelSize: Theme.caption; color: Theme.secondary
                                           Layout.fillWidth: true; elide: Text.ElideRight } }
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: sheet.selected = modelData.bank
                                onDoubleClicked: { sheet.selected = modelData.bank; sheet.next() }
                            }
                        }
                    }
                }
                RowLayout {
                    spacing: 18
                    Button { flat: true; text: qsTr("Demo-Bank ausprobieren"); onClicked: { AppModel.addDemoBank(); sheet.close() }
                             ToolTip.text: qsTr("Ohne echte Bank: Kennung „demo“, PIN 12345, beliebige TAN"); ToolTip.visible: hovered }
                    Button { flat: true; text: qsTr("Von MoneyMoney umsteigen …"); onClicked: { sheet.close(); AppModel.showMoneyMoneyImport = true } }
                }
            }

            // accessStep
            ScrollView {
                contentWidth: availableWidth
                ColumnLayout {
                    width: parent.width
                    spacing: 14
                    GroupBox {
                        visible: sheet.ways.length > 1
                        Layout.fillWidth: true
                        title: qsTr("Verbindung")
                        ColumnLayout {
                            anchors.fill: parent
                            Repeater {
                                model: sheet.ways
                                RadioButton {
                                    required property var modelData
                                    checked: sheet.selected && sheet.selected.id === modelData.id
                                    text: sheet.groupTitle(modelData.mode) + " – " + sheet.groupHint(modelData.mode)
                                    onClicked: sheet.selected = modelData
                                }
                            }
                            Text { text: qsTr("GiroCrab empfiehlt FinTS: direkt zur Bank, ohne Anmeldung bei Dritten."); font.pixelSize: Theme.caption; color: Theme.secondary }
                        }
                    }
                    Loader {
                        id: formLoader
                        Layout.fillWidth: true
                        active: sheet.step !== "bank" && sheet.selected !== null
                        sourceComponent: !sheet.selected ? null
                            : sheet.selected.mode === "FinTs" ? finTsForm
                            : sheet.selected.connector ? kindForm : psd2Form
                    }
                }
            }

            // setupStep
            ScrollView {
                contentWidth: availableWidth
                ColumnLayout {
                    width: parent.width
                    spacing: 14
                    Repeater {
                        model: sheet.step === "setup" ? sheet.missingSettings : []
                        SettingField { required property string modelData; key: modelData; Layout.fillWidth: true
                                       onEdited: v => { const x = Object.assign({}, sheet.setupValues); x[key] = v; sheet.setupValues = x } }
                    }
                }
            }
        }

        // AssistantFooter
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Button { text: qsTr("Abbrechen"); onClicked: sheet.close() }
            Item { Layout.fillWidth: true }
            Button { visible: sheet.step !== "bank"; text: qsTr("Zurück"); onClicked: sheet.back() }
            Button { text: sheet.isLastStep ? qsTr("Hinzufügen") : qsTr("Fortfahren"); highlighted: true; enabled: sheet.canContinue; onClicked: sheet.next() }
        }
    }

    // FinTsAddForm.swift
    Component {
        id: finTsForm
        ColumnLayout {
            id: ff
            spacing: 10
            readonly property var prefill: sheet.selected && sheet.selected.id !== sheet.manualFinTs.id ? sheet.selected : null
            property var presets: AppModel.core("fints_presets")
            property string blz: prefill ? prefill.blz : ""
            property string url: prefill ? prefill.url : ""
            property string bankName: prefill ? prefill.name : ""
            property var found: null
            property string autoURL: url
            property bool urlEdited: false
            readonly property bool blzValid: /^[0-9]{8}$/.test(blz)
            readonly property bool urlValid: url.startsWith("https://") && url.length > 9 && !/\s/.test(url)
            readonly property bool known: prefill !== null && found !== null
            readonly property string lc: (found ? found.name : bankName).toLowerCase()
            readonly property bool isPostbank: lc.indexOf("postbank") >= 0
            readonly property bool needsMediumHint: isPostbank || lc.indexOf("deutsche bank") >= 0 || lc.indexOf("norisbank") >= 0
            readonly property bool canAdd: blzValid && urlValid && login.text.trim() !== ""
            function lookup() {
                const info = blzValid ? AppModel.core("lookup_fints_bank_by_blz", { blz: blz }) : null
                if (!info) {
                    if (found) { found = null; if (!urlEdited && url === autoURL) { url = ""; autoURL = "" } }
                    return
                }
                found = info
                if (bankName === "") bankName = info.name
                if (!urlEdited || url === "") { autoURL = info.url; url = info.url; urlEdited = false }
            }
            function commit() {
                const name = bankName.trim()
                AppModel.addFinTsConnection(name === "" ? "FinTS-Bank " + blz : name, blz, url, login.text, tanMedium.text)
            }
            Component.onCompleted: lookup()
            onBlzChanged: lookup()

            Text { text: qsTr("Bank"); font.pixelSize: Theme.callout; font.weight: Font.DemiBold; color: Theme.secondary }
            GridLayout {
                columns: 2; columnSpacing: 12; rowSpacing: 8; Layout.fillWidth: true
                Text { visible: ff.known; text: qsTr("Bankleitzahl"); color: Theme.text }
                Text { visible: ff.known; text: ff.blz; color: Theme.secondary }
                Text { visible: ff.known; text: qsTr("Verfahren"); color: Theme.text }
                Text { visible: ff.known; text: qsTr("FinTS 3.0 mit PIN und TAN"); color: Theme.secondary }
                Text { visible: !ff.known && ff.presets.length > 1; text: qsTr("Vorlage"); color: Theme.text }
                AppComboBox {
                    visible: !ff.known && ff.presets.length > 1
                    Layout.fillWidth: true
                    model: ff.presets.map(p => p.name)
                    onActivated: i => { const p = ff.presets[i]; ff.bankName = p.id === "custom" ? "" : p.name; ff.urlEdited = false
                                        ff.autoURL = p.url; ff.url = p.url; ff.blz = p.blz; blzField.text = p.blz; urlField.text = p.url }
                }
                Text { visible: !ff.known; text: qsTr("Bankleitzahl"); color: Theme.text }
                TextField {
                    id: blzField
                    visible: !ff.known; Layout.fillWidth: true
                    placeholderText: qsTr("8 Ziffern oder IBAN"); text: ff.blz
                    onTextEdited: { const b = AppModel.core("blz_from_bank_input", { input: text }); ff.blz = b || text }
                }
                Text { visible: !ff.known && ff.found !== null; text: qsTr("Bank"); color: Theme.text }
                Text { visible: !ff.known && ff.found !== null; text: ff.found ? ff.found.name : ""; color: Theme.secondary }
                Text { text: qsTr("FinTS-Adresse"); color: Theme.text }
                TextField { id: urlField; Layout.fillWidth: true; placeholderText: "https://…"; text: ff.url
                            onTextEdited: { ff.url = text; if (text !== ff.autoURL) ff.urlEdited = true } }
            }
            Text {
                visible: !ff.known
                Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption
                color: (ff.blz !== "" && !ff.blzValid) || (ff.url !== "" && !ff.urlValid) ? "orange" : Theme.secondary
                text: (ff.blz !== "" && !ff.blzValid) || (ff.url !== "" && !ff.urlValid) ? qsTr("Bankleitzahl: genau 8 Ziffern · FinTS-Adresse: beginnt mit https://")
                    : ff.blzValid && ff.found === null ? qsTr("Diese Bankleitzahl steht nicht im Verzeichnis. Tragen Sie die FinTS-Adresse Ihrer Bank selbst ein.") : ""
            }
            Text { text: qsTr("Anmeldung"); font.pixelSize: Theme.callout; font.weight: Font.DemiBold; color: Theme.secondary; Layout.topMargin: 6 }
            DemoHintBanner { visible: AppModel.demoActive || ff.blz === "99999999"; Layout.fillWidth: true; onFill: login.text = "demo" }
            GridLayout {
                columns: 2; columnSpacing: 12; rowSpacing: 8; Layout.fillWidth: true
                Text { text: qsTr("Anmeldename"); color: Theme.text }
                TextField { id: login; Layout.fillWidth: true; placeholderText: ff.isPostbank ? qsTr("Postbank ID") : qsTr("z. B. VR-NetKey oder Kontonummer") }
                Text { text: qsTr("TAN-Medium"); color: Theme.text }
                TextField { id: tanMedium; Layout.fillWidth: true; placeholderText: qsTr("Optional") }
            }
            AddFormFooter {
                lines: [ff.isPostbank ? qsTr("Postbank: Als Anmeldename die Postbank ID verwenden, nicht die Kontonummer.") : "",
                        ff.needsMediumHint ? qsTr("Fordert die Bank ein TAN-Medium (Fehler 9210), tragen Sie den Gerätenamen aus der BestSign- oder App-Verwaltung ein, z. B. SO:Gerätename.")
                                           : qsTr("Das TAN-Medium brauchen Sie nur, wenn die Bank danach fragt.")]
            }
        }
    }

    // BankPicker.swift › KindAddForm (own API: comdirect, Trade Republic, PayPal, …)
    Component {
        id: kindForm
        ColumnLayout {
            id: kf
            spacing: 10
            readonly property string kind: sheet.selected.connector
            readonly property var d: AppModel.descriptor(kind)
            readonly property bool loginRequired: ["Comdirect", "TradeRepublic", "VolksbankKasselGoettingen", "Direkt1822", "FinTsGeneric"].indexOf(kind) >= 0
            readonly property bool canAdd: !loginRequired || login.text.trim() !== ""
            function commit() {
                AppModel.addConnection(kind, kind === "TradeRepublic" ? AppModel.core("normalize_phone_number", { input: login.text }) : login.text)
            }
            Text { text: qsTr("Zugang"); font.pixelSize: Theme.callout; font.weight: Font.DemiBold; color: Theme.secondary }
            DemoHintBanner { visible: AppModel.demoActive; Layout.fillWidth: true; onFill: login.text = "demo" }
            GridLayout {
                columns: 2; columnSpacing: 12; rowSpacing: 8; Layout.fillWidth: true
                Text { text: kf.d ? kf.d.login_label : ""; color: Theme.text }
                TextField { id: login; Layout.fillWidth: true; placeholderText: kf.loginRequired ? "" : qsTr("Optional") }
                Text { text: qsTr("Verfahren"); color: Theme.text }
                Text { text: kf.d ? kf.d.protocol : ""; color: Theme.secondary }
                Text { visible: kf.d && kf.d.bank_code !== ""; text: qsTr("Bankleitzahl"); color: Theme.text }
                Text { visible: kf.d && kf.d.bank_code !== ""; text: kf.d ? kf.d.bank_code : ""; color: Theme.secondary }
            }
            AddFormFooter { lines: [kf.d ? kf.d.note : ""] }
        }
    }

    // BankPicker.swift › Psd2AddForm
    Component {
        id: psd2Form
        ColumnLayout {
            spacing: 10
            readonly property bool canAdd: true
            function commit() { AppModel.addEnableBankingConnection(sheet.selected.aspsp, sheet.selected.country, sheet.selected.name, label.text) }
            Text { text: qsTr("Zugang"); font.pixelSize: Theme.callout; font.weight: Font.DemiBold; color: Theme.secondary }
            GridLayout {
                columns: 2; columnSpacing: 12; rowSpacing: 8; Layout.fillWidth: true
                Text { text: qsTr("Land"); color: Theme.text }
                Text { text: sheet.selected.country; color: Theme.secondary }
                Text { text: qsTr("Verfahren"); color: Theme.text }
                Text { text: qsTr("PSD2 über Enable Banking"); color: Theme.secondary }
            }
            DemoHintBanner { visible: AppModel.demoActive; Layout.fillWidth: true; onFill: label.text = "demo" }
            GridLayout {
                columns: 2; columnSpacing: 12; Layout.fillWidth: true
                Text { text: qsTr("Bezeichnung"); color: Theme.text }
                TextField { id: label; Layout.fillWidth: true; placeholderText: qsTr("Optional") }
            }
            AddFormFooter { lines: [sheet.selected.tested, qsTr("Sie melden sich in einem GiroCrab-Fenster direkt bei Ihrer Bank an. Dafür brauchen Sie eine kostenlose eigene Anwendung auf enablebanking.com – die Einrichtung führt Sie Schritt für Schritt hindurch.")] }
        }
    }

    component AddFormFooter: ColumnLayout {
        property var lines: []
        Layout.fillWidth: true
        spacing: 4
        Repeater {
            model: parent.lines.filter(l => l)
            Text { required property string modelData; text: modelData; Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption; color: Theme.secondary }
        }
        Text { text: qsTr("Gibt es den Zugang schon (gleiche Bank, gleiche Kennung), wird er aktualisiert statt doppelt angelegt.")
               Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption; color: Theme.secondary }
    }
}
