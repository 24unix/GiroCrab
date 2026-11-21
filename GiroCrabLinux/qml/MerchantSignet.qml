import QtQuick
import QtQuick.Shapes

// MerchantSignet.swift › MerchantSignet: person initials, downloaded favicon (Tier 2, only
// with online logos on, MerchantLogos.qml), brand SVG (simple-icons), category symbol for
// unknown merchants, else the brand monogram.
Item {
    id: root
    property var merchant
    property string categorySymbol: ""
    property int size: 36
    property bool showNewDot: false
    /// Drawn size: grows with the text size like on the Mac (#343).
    readonly property int px: Theme.scaled(size)
    width: px; height: px
    // .accessibilityLabel(showNewDot ? "\(name), neu" : name) (ff91866): the blue dot is the only
    // "new" signal on screen, so it is said too; the name follows the redaction.
    readonly property string spokenName: !merchant ? "" : merchant.is_person || !merchant.known ? AppModel.masking(merchant.name || "") : (merchant.name || "")
    Accessible.role: Accessible.Graphic
    Accessible.name: showNewDot && spokenName !== "" ? qsTr("%1, neu").arg(spokenName) : spokenName

    readonly property bool person: merchant && merchant.is_person
    readonly property bool hasSvg: merchant && merchant.svg_path !== ""
    readonly property color brand: merchant && merchant.color_hex ? merchant.color_hex : Theme.tertiary

    /// model.cachedLogo(for:): `{ url, pixels }` or null; vanishes at once with "Aus" (#422).
    readonly property var logo: {
        MerchantLogos.version
        return person ? null : MerchantLogos.cachedLogo(merchant)
    }
    /// `pixels >= 48`: a real brand logo, shown before the bundled SVG
    readonly property bool sharpLogo: logo !== null && logo.pixels >= 48
    /// small favicons only for known brands – a guessed domain must deliver a sharp logo
    readonly property bool smallLogo: logo !== null && !sharpLogo && !hasSvg && merchant
                                      && (merchant.domain_source === "dictionary" || merchant.domain_source === "override")
    readonly property bool showsLogo: sharpLogo || smallLogo
    readonly property bool useCategory: merchant && !merchant.known && categorySymbol !== "" && !hasSvg && !person && !showsLogo

    /// `.task(id:)`: candidates + domain + provider + logoVersion – a reused row or a new
    /// provider asks again; a cached logo is drawn above without a request.
    readonly property string logoTaskID: person || !merchant ? ""
        : MerchantLogos.key(merchant) + "|" + merchant.domain + "|" + MerchantLogos.provider + "|" + MerchantLogos.epoch
    onLogoTaskIDChanged: if (logoTaskID !== "" && MerchantLogos.onlineLogos) MerchantLogos.request(merchant)
    Component.onCompleted: if (logoTaskID !== "" && MerchantLogos.onlineLogos) MerchantLogos.request(merchant)

    Rectangle {
        anchors.fill: parent
        radius: root.person ? width / 2 : root.px * 0.28
        color: root.person ? Theme.personFill
             : root.showsLogo ? "white"
             : root.useCategory ? Theme.neutralTile
             : Theme.withAlpha(root.brand, root.hasSvg ? 0.09 : 0.10)
        border.width: root.person ? 0 : 1
        border.color: root.sharpLogo ? Theme.border : Theme.withAlpha(root.brand, 0.16)
    }
    Image {
        visible: root.showsLogo
        anchors.fill: parent
        anchors.margins: root.px * (root.sharpLogo ? 0.14 : 0.2)
        source: root.showsLogo ? root.logo.url : ""
        // decodeLogo: a thumbnail of at most 128 px, decoded off the GUI thread
        sourceSize: Qt.size(128, 128)
        asynchronous: true
        fillMode: Image.PreserveAspectFit
        smooth: true; mipmap: true
    }
    Text {
        visible: root.person || (!root.hasSvg && !root.useCategory && !root.showsLogo)
        anchors.centerIn: parent
        text: root.merchant ? root.merchant.monogram : ""
        font.pixelSize: root.px * (root.person ? 0.36 : (text.length > 2 ? 0.30 : 0.40))
        font.weight: root.person ? Font.DemiBold : Font.Bold
        color: root.person ? Theme.personText : Theme.readable(root.merchant ? root.merchant.color_hex : "")
        // a person's initials, or those of an unknown counterparty
        Sensitive { when: root.person || !(root.merchant && root.merchant.known) }
    }
    SFIcon {
        visible: root.useCategory
        anchors.centerIn: parent
        symbol: root.categorySymbol
        size: root.px * 0.5
        color: Theme.secondary
    }
    Shape {
        visible: root.hasSvg && !root.person && !root.sharpLogo
        anchors.fill: parent
        anchors.margins: root.px * 0.2
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            fillColor: Theme.readable(root.merchant ? root.merchant.color_hex : "")
            strokeWidth: -1
            fillRule: ShapePath.WindingFill // FillStyle(eoFill: false)
            scale: Qt.size((root.px * 0.6) / 24, (root.px * 0.6) / 24)
            PathSvg { path: root.hasSvg ? root.merchant.svg_path : "" }
        }
    }
    Rectangle {
        visible: root.showNewDot
        width: 8; height: 8; radius: 4
        color: Theme.accent
        border.color: Theme.card; border.width: 1.5
        x: parent.width - 6; y: -2
    }
}
