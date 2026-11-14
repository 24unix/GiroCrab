import QtQuick
import QtQuick.Controls
import QtQuick.Effects

// A Menu that is as wide as its widest entry (Qt Quick menus default to a fixed
// 200 px and elide longer titles) and shows Action shortcuts (AppMenuItem).
// anyCheckable / anyIcon let every AppMenuItem reserve the same leading columns,
// so all titles of one menu start on one line (as in macOS menus).
Menu {
    id: menu
    // Separate bindings on purpose: the entries' widths depend on anyCheckable/anyIcon,
    // so those two must not read implicitWidth (no binding loop).
    readonly property bool anyCheckable: {
        if (!visible) return false   // closed menus cost nothing (long, rebuilt menus)
        for (let i = 0; i < count; ++i) { const it = itemAt(i); if (it && it.checkable) return true }
        return false
    }
    readonly property bool anyIcon: {
        if (!visible) return false
        for (let i = 0; i < count; ++i) {
            const it = itemAt(i)
            if (it && it.icon && (it.icon.name !== "" || it.icon.source.toString() !== "")) return true
        }
        return false
    }
    readonly property real widestItem: {
        if (!visible) return 0
        let w = 0
        for (let i = 0; i < count; ++i) { const it = itemAt(i); if (it && it.implicitWidth > w) w = it.implicitWidth }
        return w
    }
    width: Math.max(200, Math.ceil(widestItem) + leftPadding + rightPadding + 8)
    delegate: AppMenuItem {}

    // Look of GiroCrab's cards: rounded, card colour, soft border and shadow.
    topPadding: 5; bottomPadding: 5; leftPadding: 5; rightPadding: 5
    background: Rectangle {
        implicitWidth: 200
        radius: 9
        color: Theme.card
        border.color: Theme.border
        layer.enabled: true
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: "#000000"
            shadowOpacity: Theme.dark ? 0.55 : 0.18
            shadowBlur: 0.7
            shadowVerticalOffset: 3
        }
    }
}
