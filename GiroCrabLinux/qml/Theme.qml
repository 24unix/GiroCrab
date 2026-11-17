pragma Singleton
import QtQuick
import QtCore

// Formatting.swift › enum Theme: "Daylight" / "Nightfall" design tokens.
QtObject {
    id: theme
    /// Einstellungen › Allgemein › Erscheinungsbild (Appearance.swift, GitHub #388): `appearance`
    /// = "system", "light" or "dark", the Mac's defaults key. Forced through this file alone (no
    /// QStyleHints::setColorScheme, which Qt 6.6 lacks), like `--dark` / `--light`.
    readonly property Settings appearanceSettings: Settings { property string appearance: "system" }
    /// `--dark` / `--light` (LaunchOptions.swift) or the appearance setting: "dark" / "light" force
    /// the appearance, "" = system. Screenshot launches follow the system unless forced by flag.
    readonly property string forced: Qt.application.arguments.indexOf("--dark") >= 0 ? "dark"
        : Qt.application.arguments.indexOf("--light") >= 0 ? "light"
        : Qt.application.arguments.indexOf("--screenshot") >= 0 ? ""
        : ["light", "dark"].indexOf(appearanceSettings.appearance) >= 0 ? appearanceSettings.appearance : ""
    readonly property bool dark: forced !== "" ? forced === "dark" : Application.styleHints.colorScheme === Qt.ColorScheme.Dark
    function c(light, darkHex) { return dark ? darkHex : light }

    readonly property color canvas: c("#F8FAFC", "#0F172A")
    readonly property color sidebar: c("#F3F4F6", "#0B1220")
    readonly property color card: c("#FFFFFF", "#1E293B")
    readonly property color border: c("#E2E8F0", "#334155")
    readonly property color text: c("#0F172A", "#F1F5F9")
    readonly property color secondary: c("#4B5A70", "#A3B1C4")
    readonly property color tertiary: c("#64748B", "#8494AA")
    readonly property color outflow: c("#0F172A", "#F1F5F9")
    /// Emerald; light #047857 (was #059669, only 3.8:1 on white – e33d9bc, #571).
    readonly property color inflow: c("#047857", "#34D399")
    readonly property color inflowBadge: c("#ECFDF5", "#064E3B")
    /// Order-account charge colour: the red counterpart of `inflow`, paired
    /// with `outflowBadge` so badged charges and refunds read symmetrically.
    readonly property color charge: c("#B91C1C", "#F87171")
    /// Red counterpart of `inflowBadge`, so the order-account rows can badge
    /// charges and refunds symmetrically (direction additionally via sign).
    readonly property color outflowBadge: c("#FEF2F2", "#5B1B1B")
    // AccentColor of the asset catalog (GiroCrab blue).
    readonly property color accent: c("#2563EB", "#60A5FA")
    readonly property color selection: Qt.rgba(accent.r, accent.g, accent.b, dark ? 0.28 : 0.13)
    readonly property color loan: c("#64748B", "#94A3B8")
    readonly property color warning: c("#B45309", "#F59E0B")
    readonly property color invest: c("#1F7A5C", "#5EC79F")
    readonly property color negative: c("#B91C1C", "#F87171")
    readonly property color personFill: c("#E2E8F0", "#334155")
    /// PrivacyRedaction.swift `Color.redactionFill` (systemGray): the opaque box of `Sensitive`.
    readonly property color redactionFill: "#8E8E93"
    readonly property color personText: c("#475569", "#CBD5E1")
    readonly property color neutralTile: c("#F1F3F5", "#273449")

    // TextSize.swift › AppTextSize (#343): text size of the whole app, Einstellungen › Allgemein ›
    // Schriftgröße and Darstellung › Größer / Kleiner / Originalgröße.
    readonly property var textSizes: [
        { id: "standard", title: qsTr("Standard"), scale: 1 },
        { id: "large", title: qsTr("Groß"), scale: 1.15 },
        { id: "larger", title: qsTr("Sehr groß"), scale: 1.3 }]
    /// `@AppStorage("textSize")`: key `textSize` in GiroCrab.conf.
    property Settings textSizeDefaults: Settings { property string textSize: "standard" }
    /// The stored choice (unknown values count as "standard", like a failed raw value).
    readonly property string textSize: textSizes.some(s => s.id === textSizeDefaults.textSize) ? textSizeDefaults.textSize : "standard"
    function setTextSize(id) { textSizeDefaults.textSize = id }
    /// AppTextSize.larger / .smaller: the next size, "" at the end of the range.
    function steppedTextSize(delta) {
        const i = textSizes.findIndex(s => s.id === textSize) + delta
        return i >= 0 && i < textSizes.length ? textSizes[i].id : ""
    }
    /// AppTextSize.effective: `--text-size <standard|large|larger>` wins; screenshot
    /// launches otherwise stay at "standard" (reproducible pictures).
    readonly property string effectiveTextSize: {
        const args = Qt.application.arguments
        const i = args.indexOf("--text-size")
        const forced = i >= 0 && i + 1 < args.length ? args[i + 1].toLowerCase() : ""
        if (textSizes.some(s => s.id === forced)) return forced
        return args.indexOf("--screenshot") >= 0 ? "standard" : textSize
    }
    /// `@Environment(\.textScale)`: factor for text and for fixed sizes that hold text.
    readonly property real textScale: textSizes.find(s => s.id === effectiveTextSize).scale
    /// macSize(scale:): whole pixels stay crisp (caption 10 → 12 → 13, body 13 → 15 → 17).
    function scaled(size) { return Math.round(size * textScale) }
    /// Default font of the controls (labels, check boxes, pickers) at the current scale:
    /// bound to `font.pointSize` of every window (appTextSize on the Mac). Menus keep the
    /// system size (AppMenu, MenuBar), as on the Mac.
    readonly property real controlPointSize: (Qt.application.font.pointSize > 0 ? Qt.application.font.pointSize : 10) * textScale

    // SwiftUI text styles (macOS point sizes), scaled by the text size.
    readonly property int largeTitle: scaled(26)
    readonly property int title: scaled(22)
    readonly property int title2: scaled(17)
    readonly property int title3: scaled(15)
    readonly property int body: scaled(13)
    readonly property int callout: scaled(12)
    readonly property int subheadline: scaled(11)
    readonly property int caption: scaled(10)
    readonly property int caption2: scaled(10)

    // Color.readable(hex:): brand/category colours, lightened in dark mode.
    function readable(hex) {
        if (!hex || hex.length < 7) return tertiary
        const col = Qt.color(hex)
        if (!dark) return col
        return Qt.lighter(col, col.hslLightness < 0.45 ? 1.6 : 1.15)
    }
    function withAlpha(col, a) { return Qt.alpha(col, a) }

    /// The controls' palette while the appearance is forced (`--dark` / `--light`): the
    /// desktop's colour scheme (e.g. KDE) would otherwise keep its own colours. Every
    /// top-level window binds it while `forced` is set.
    readonly property Palette forcedPalette: Palette {
        window: theme.canvas; windowText: theme.text; base: theme.card; alternateBase: theme.sidebar; text: theme.text
        button: theme.card; buttonText: theme.text; toolTipBase: theme.card; toolTipText: theme.text
        placeholderText: theme.tertiary; mid: theme.border; midlight: theme.border
        light: theme.c("#FFFFFF", "#475569"); dark: theme.c("#94A3B8", "#020617"); shadow: theme.c("#64748B", "#000000")
        highlight: theme.accent; highlightedText: theme.c("#FFFFFF", "#0F172A")
        accent: theme.accent; link: theme.accent; brightText: "#FFFFFF"
        disabled.windowText: theme.tertiary; disabled.text: theme.tertiary; disabled.buttonText: theme.tertiary
    }
}
