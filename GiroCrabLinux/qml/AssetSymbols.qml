pragma Singleton
import QtQuick

// TangibleAssetsUI.swift › AssetSymbols: the icons an asset can carry (SF Symbol names, like
// every other icon in the app; drawn with the nearest Breeze icon or an own drawing).
QtObject {
    /// Own drawings for what SF Symbols lacks.
    readonly property string gem: "girocrab.gem"
    readonly property string necklace: "girocrab.necklace"
    /// Preselected for items created from now on.
    readonly property string newItemDefault: "diamond.fill"

    readonly property var groups: [
        { title: qsTr("Edelmetalle & Schmuck"), items: [
            { symbol: "seal.fill", name: qsTr("Münze") }, { symbol: "rectangle.stack.fill", name: qsTr("Barren") },
            { symbol: gem, name: qsTr("Edelstein") }, { symbol: necklace, name: qsTr("Kette") },
            { symbol: "crown.fill", name: qsTr("Schmuck") }, { symbol: "watch.analog", name: qsTr("Uhr") }] },
        { title: qsTr("Immobilien"), items: [
            { symbol: "house.fill", name: qsTr("Haus") }, { symbol: "building.2.fill", name: qsTr("Wohnung") },
            { symbol: "building.columns.fill", name: qsTr("Gewerbe") }, { symbol: "tree.fill", name: qsTr("Grundstück") }] },
        { title: qsTr("Fahrzeuge"), items: [
            { symbol: "car.side.fill", name: qsTr("Auto") }, { symbol: "motorcycle", name: qsTr("Motorrad") },
            { symbol: "bicycle", name: qsTr("Fahrrad") }, { symbol: "sailboat.fill", name: qsTr("Boot") },
            { symbol: "airplane", name: qsTr("Flugzeug") }] },
        { title: qsTr("Anlagen"), items: [
            { symbol: "chart.line.uptrend.xyaxis", name: qsTr("Wertpapiere") }, { symbol: "chart.pie.fill", name: qsTr("Beteiligung") },
            { symbol: "bitcoinsign.circle.fill", name: qsTr("Krypto") }, { symbol: "banknote.fill", name: qsTr("Bargeld") },
            { symbol: "briefcase.fill", name: qsTr("Firma") }] },
        { title: qsTr("Sammeln & Sonstiges"), items: [
            { symbol: "photo.artframe", name: qsTr("Kunst") }, { symbol: "guitars.fill", name: qsTr("Instrument") },
            { symbol: "wineglass.fill", name: qsTr("Wein") }, { symbol: "book.closed.fill", name: qsTr("Sammlung") },
            { symbol: "camera.fill", name: qsTr("Kamera") }, { symbol: "desktopcomputer", name: qsTr("Technik") },
            { symbol: "diamond.fill", name: qsTr("Wertgegenstand") }, { symbol: "shippingbox.fill", name: qsTr("Sonstiges") }] }
    ]

    /// Without a chosen icon: gold shows a coin, everything else a box.
    function defaultSymbol(source) { return source === "manual" ? "shippingbox.fill" : "seal.fill" }
    function symbolOf(item) { return item.setup.symbol === "" ? defaultSymbol(item.setup.price_source) : item.setup.symbol }
    function nameOf(symbol) {
        for (const g of groups) for (const i of g.items) if (i.symbol === symbol) return i.name
        return qsTr("Symbol")
    }

    /// Breeze icons for the asset symbols SF.qml does not know (closest match).
    readonly property var breeze: ({
        "seal.fill": "format-currency", "rectangle.stack.fill": "view-financial-account-savings",
        "crown.fill": "draw-star", "watch.analog": "clock", "house.fill": "go-home", "building.2.fill": "view-bank",
        "building.columns.fill": "view-bank", "tree.fill": "map-flat", "car.side.fill": "car",
        "motorcycle": "car", "bicycle": "car", "sailboat.fill": "transport-mode-flight", "airplane": "transport-mode-flight",
        "chart.line.uptrend.xyaxis": "view-financial-account-investment", "chart.pie.fill": "office-chart-pie",
        "bitcoinsign.circle.fill": "view-financial-account-investment", "banknote.fill": "view-financial-account-savings",
        "briefcase.fill": "view-financial-account", "photo.artframe": "viewimage", "guitars.fill": "folder-music",
        "wineglass.fill": "wine", "book.closed.fill": "address-book-new", "camera.fill": "camera-photo",
        "desktopcomputer": "computer", "shippingbox.fill": "package"
    })
}
