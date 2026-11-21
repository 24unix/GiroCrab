import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// SymbolPicker.swift › SymbolCatalog + SymbolPicker: a curated, themed list of
// SF Symbols (sections by topic plus a search over names and symbol names).
// The symbols are stored in the vault; SF.icon draws the matching Breeze icon.
// Picks on click and emits `picked` (closes a popup).
Rectangle {
    id: picker
    property string selection: ""
    property color tint: Theme.accent
    signal picked(string symbol)
    implicitWidth: 360
    implicitHeight: 420
    color: "transparent"

    function i(symbol, name) { return { symbol: symbol, name: name } }
    readonly property var sections: [
        { title: qsTr("Finanzen"), items: [
            i("banknote", qsTr("Geld")), i("creditcard", qsTr("Kreditkarte")), i("eurosign.circle", qsTr("Bargeld")),
            i("dollarsign.circle", qsTr("Dollar")), i("building.columns", qsTr("Bank")), i("envelope.circle", qsTr("Bezahldienst")), i("wallet.bifold", qsTr("Geldbörse")),
            i("chart.pie", qsTr("Vermögen")), i("chart.line.uptrend.xyaxis", qsTr("Depot")), i("percent", qsTr("Zinsen")),
            i("bitcoinsign.circle", qsTr("Krypto")), i("giftcard", qsTr("Gutschein")), i("arrow.left.arrow.right", qsTr("Umbuchung")),
            i("lock.shield", qsTr("Sicherheit")), i("doc.text", qsTr("Vertrag")), i("building.2", qsTr("Firma")) ] },
        { title: qsTr("Haushalt"), items: [
            i("house", qsTr("Haus")), i("key", qsTr("Miete")), i("cart", qsTr("Einkauf")), i("basket", qsTr("Korb")),
            i("fork.knife", qsTr("Essen")), i("cup.and.saucer", qsTr("Café")), i("lightbulb", qsTr("Strom")), i("flame", qsTr("Heizung")),
            i("drop", qsTr("Wasser")), i("wifi", qsTr("Internet")), i("phone", qsTr("Telefon")), i("tv", qsTr("Fernsehen")),
            i("sofa", qsTr("Möbel")), i("washer", qsTr("Waschmaschine")), i("wrench.and.screwdriver", qsTr("Reparatur")),
            i("leaf", qsTr("Garten")), i("trash", qsTr("Müll")) ] },
        { title: qsTr("Mobilität"), items: [
            i("car", qsTr("Auto")), i("fuelpump", qsTr("Tanken")), i("bolt.car", qsTr("Elektroauto")), i("bus", qsTr("Bus")),
            i("tram", qsTr("Straßenbahn")), i("train.side.front.car", qsTr("Zug")), i("bicycle", qsTr("Fahrrad")),
            i("scooter", qsTr("Roller")), i("airplane", qsTr("Reisen")), i("ferry", qsTr("Fähre")),
            i("parkingsign.circle", qsTr("Parken")), i("figure.walk", qsTr("Zu Fuß")) ] },
        { title: qsTr("Freizeit"), items: [
            i("gamecontroller", qsTr("Spiele")), i("film", qsTr("Kino")), i("music.note", qsTr("Musik")), i("book", qsTr("Bücher")),
            i("theatermasks", qsTr("Theater")), i("sportscourt", qsTr("Sport")), i("figure.run", qsTr("Laufen")),
            i("dumbbell", qsTr("Fitness")), i("tent", qsTr("Camping")), i("beach.umbrella", qsTr("Urlaub")),
            i("camera", qsTr("Fotografie")), i("paintpalette", qsTr("Kunst")), i("ticket", qsTr("Tickets")),
            i("party.popper", qsTr("Feier")) ] },
        { title: qsTr("Familie"), items: [
            i("person", qsTr("Person")), i("person.2", qsTr("Paar")), i("person.3", qsTr("Gruppe")),
            i("figure.and.child.holdinghands", qsTr("Familie")), i("figure.2.and.child.holdinghands", qsTr("Kinder")),
            i("stroller", qsTr("Baby")), i("heart", qsTr("Herz")), i("gift", qsTr("Geschenk")), i("birthday.cake", qsTr("Geburtstag")),
            i("teddybear", qsTr("Spielzeug")), i("graduationcap", qsTr("Ausbildung")), i("backpack", qsTr("Schule")),
            i("pawprint", qsTr("Haustier")) ] },
        { title: qsTr("Beruf"), items: [
            i("briefcase", qsTr("Beruf")), i("laptopcomputer", qsTr("Computer")), i("printer", qsTr("Drucker")),
            i("folder", qsTr("Ordner")), i("tray.full", qsTr("Ablage")), i("envelope", qsTr("Post")), i("calendar", qsTr("Kalender")),
            i("hammer", qsTr("Werkzeug")), i("signature", qsTr("Unterschrift")), i("chart.bar", qsTr("Statistik")) ] },
        { title: qsTr("Gesundheit"), items: [
            i("cross.case", qsTr("Apotheke")), i("pills", qsTr("Medikamente")), i("stethoscope", qsTr("Arzt")),
            i("heart.text.square", qsTr("Gesundheit")), i("bandage", qsTr("Pflaster")), i("eyeglasses", qsTr("Brille")),
            i("figure.mind.and.body", qsTr("Wellness")), i("bed.double", qsTr("Schlaf")), i("scissors", qsTr("Friseur")),
            i("shield", qsTr("Versicherung")), i("umbrella", qsTr("Schutz")) ] },
        { title: qsTr("Sonstiges"), items: [
            i("tshirt", qsTr("Kleidung")), i("bag", qsTr("Einkaufstasche")), i("tag", qsTr("Etikett")), i("star", qsTr("Favorit")),
            i("flag", qsTr("Flagge")), i("globe", qsTr("Welt")), i("cloud", qsTr("Cloud")), i("sparkles", qsTr("Besonderes")),
            i("hand.raised", qsTr("Spende")), i("ellipsis.circle", qsTr("Andere")), i("questionmark.circle", qsTr("Unbekannt")) ] }
    ]

    /// Opens at the section of the current symbol (SymbolPicker.swift › onAppear).
    function scrollToSelection() {
        const idx = shown.findIndex(s => s.items.some(x => x.symbol === selection))
        const item = idx >= 0 ? sectionRepeater.itemAt(idx) : null
        const flick = scroll.contentItem
        if (!item || !flick) return
        flick.contentY = Math.max(0, Math.min(item.y, flick.contentHeight - flick.height))
    }
    onVisibleChanged: if (visible) Qt.callLater(scrollToSelection)
    Component.onCompleted: Qt.callLater(scrollToSelection)

    /// SymbolCatalog.search: name or symbol name, ignoring case and diacritics.
    readonly property var shown: {
        const q = Fmt.fold(query.text.trim())
        let result = sections
        if (q !== "") {
            result = []
            for (const s of sections) {
                const hits = s.items.filter(x => Fmt.fold(x.name).indexOf(q) >= 0 || x.symbol.indexOf(q) >= 0)
                if (hits.length) result.push({ title: s.title, items: hits })
            }
        } else if (selection !== "" && !sections.some(s => s.items.some(x => x.symbol === selection))) {
            // the current symbol on top when it is not in the catalogue
            result = [{ title: qsTr("Aktuell"), items: [i(selection, selection)] }].concat(sections)
        }
        return result
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        TextField {
            id: query
            Layout.fillWidth: true
            Layout.margins: 10
            placeholderText: qsTr("Symbole durchsuchen")
            leftPadding: 28
            SFIcon { symbol: "magnifyingglass"; size: 14; anchors.verticalCenter: parent.verticalCenter; x: 8 }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }
        ScrollView {
            ScrollBar.vertical: ScrollViewBar {}
            id: scroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: availableWidth
            clip: true
            Text {
                visible: picker.shown.length === 0
                width: scroll.availableWidth
                topPadding: 40
                horizontalAlignment: Text.AlignHCenter
                text: qsTr("Keine Treffer")
                color: Theme.secondary
                font.pixelSize: Theme.body
            }
            Column {
                id: sectionsColumn
                width: scroll.availableWidth
                padding: 12
                spacing: 12
                Repeater {
                    id: sectionRepeater
                    model: picker.shown
                    Column {
                        id: sec
                        required property var modelData
                        width: sectionsColumn.width - 24
                        spacing: 8
                        Text { text: sec.modelData.title; font.pixelSize: Theme.subheadline + 1; font.weight: Font.DemiBold; color: Theme.secondary }
                        Flow {
                            width: parent.width
                            spacing: 6
                            Repeater {
                                model: sec.modelData.items
                                Rectangle {
                                    id: cell
                                    required property var modelData
                                    readonly property bool isSelected: modelData.symbol === picker.selection
                                    width: 36; height: 36; radius: 8
                                    color: isSelected ? Theme.withAlpha(picker.tint, 0.18) : (hover.hovered ? Theme.withAlpha(Theme.secondary, 0.08) : "transparent")
                                    border.color: isSelected ? picker.tint : "transparent"
                                    SFIcon { anchors.centerIn: parent; symbol: cell.modelData.symbol; size: 18; color: cell.isSelected ? picker.tint : Theme.secondary }
                                    HoverHandler { id: hover }
                                    ToolTip.visible: hover.hovered
                                    ToolTip.delay: 600
                                    ToolTip.text: cell.modelData.name
                                    // only emit: the owner updates `selection` (assigning it here would cut its binding)
                                    TapHandler { onTapped: picker.picked(cell.modelData.symbol) }
                                    // GroupDetailEditor: German symbol names instead of SF identifiers (ff91866)
                                    Accessible.role: Accessible.Button
                                    Accessible.name: cell.modelData.name
                                    Accessible.selected: cell.isSelected
                                    Accessible.onPressAction: picker.picked(cell.modelData.symbol)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
