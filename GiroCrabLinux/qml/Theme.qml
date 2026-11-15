pragma Singleton
import QtQuick

// Formatting.swift › enum Theme: "Daylight" / "Nightfall" design tokens.
QtObject {
    id: theme
    /// `--dark` / `--light` (LaunchOptions.swift): "dark" / "light" force the appearance, "" = system.
    readonly property string forced: Qt.application.arguments.indexOf("--dark") >= 0 ? "dark"
        : Qt.application.arguments.indexOf("--light") >= 0 ? "light" : ""
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
    readonly property color inflow: c("#059669", "#34D399")
    readonly property color inflowBadge: c("#ECFDF5", "#064E3B")
    // AccentColor of the asset catalog (GiroCrab blue).
    readonly property color accent: c("#2563EB", "#60A5FA")
    readonly property color selection: Qt.rgba(accent.r, accent.g, accent.b, dark ? 0.28 : 0.13)
    readonly property color loan: c("#64748B", "#94A3B8")
    readonly property color warning: c("#B45309", "#F59E0B")
    readonly property color invest: c("#1F7A5C", "#5EC79F")
    readonly property color negative: c("#B91C1C", "#F87171")
    readonly property color personFill: c("#E2E8F0", "#334155")
    readonly property color personText: c("#475569", "#CBD5E1")
    readonly property color neutralTile: c("#F1F3F5", "#273449")

    // SwiftUI text styles (macOS point sizes).
    readonly property int largeTitle: 26
    readonly property int title: 22
    readonly property int title2: 17
    readonly property int title3: 15
    readonly property int body: 13
    readonly property int callout: 12
    readonly property int subheadline: 11
    readonly property int caption: 10
    readonly property int caption2: 10

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
