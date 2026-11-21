pragma Singleton
import QtQuick

// SF Symbols (stored in the vault and used throughout the Swift UI) → freedesktop /
// Breeze icon names. Matching is by full name, then by the name without
// ".fill"/".circle" suffixes, then by the first component.
QtObject {
    readonly property var map: ({
        "rectangle.split.3x1": "view-split-left-right", "plus.square": "list-add", "square.stack.3d.up": "view-list-tree",
        "building.columns": "view-bank", "building.2": "view-bank", "banknote": "view-financial-account-savings",
        "creditcard": "view-financial-account-credit-card", "envelope.circle": "mail-send",
        "chart.line.uptrend.xyaxis": "view-financial-account-investment", "eurosign": "view-financial-account-cash",
        "house": "go-home", "bitcoinsign": "view-financial-account-investment", "p": "view-financial-account",
        "square.grid.2x2": "view-grid", "doc.on.doc": "edit-copy", "doc.text": "document-multiple",
        "doc": "document-new", "doc.text.magnifyingglass": "document-preview", "questionmark.folder": "folder",
        "questionmark": "dialog-question", "plus": "list-add", "minus": "list-remove", "folder.badge.plus": "folder-new",
        "folder": "folder", "lock": "object-locked", "lock.open": "object-unlocked", "lock.slash": "object-unlocked",
        "theatermasks": "view-media-artist", "chevron.right": "go-next", "chevron.down": "go-down",
        "calendar": "view-calendar", "line.3.horizontal.decrease": "view-filter", "magnifyingglass": "edit-find",
        "paperplane": "mail-send", "arrow.triangle.2.circlepath": "view-refresh", "sidebar.trailing": "sidebar-collapse-right",
        "checkmark": "dialog-ok",   // light Breeze has "checkmark" only as an emblem (a filled badge)
        "checkmark.circle": "dialog-ok-apply", "repeat": "media-playlist-repeat",
        "equal.circle": "document-equal",
        "clock": "clock", "tag": "tag", "note.text": "note", "pencil": "document-edit", "trash": "edit-delete",
        "paintpalette": "color-picker", "wand.and.stars": "tools-wizard", "arrow.triangle.branch": "split",
        "archivebox": "archive-insert", "gearshape": "settings-configure", "printer": "document-print",
        "square.and.arrow.up": "document-export", "square.and.arrow.down": "document-import", "command": "code-context",
        "square.and.arrow.down.on.square": "document-import",
        "exclamationmark.triangle": "dialog-warning", "exclamationmark.shield": "security-low", "globe": "globe-symbolic",
        "person": "im-user", "tray": "mail-folder-inbox", "chart.bar.xaxis": "office-chart-bar", "chart.bar": "office-chart-bar",
        "chart.pie": "office-chart-pie", "chart.xyaxis.line": "office-chart-line", "arrow.down": "view-financial-category-income",
        "arrow.left.arrow.right": "exchange-positions", "cart": "view-financial-category-expense",
        "car": "car", "tram": "car", "fuelpump": "car", "fork.knife": "fork", "takeoutbag.and.cup.and.straw": "fork",
        "bag": "view-financial-category-expense", "shippingbox": "package", "gift": "favorite", "sofa": "go-home",
        "bolt": "battery", "leaf": "games-hint", "cross.case": "security-high", "cross.vial": "security-high",
        "shield": "security-high", "shield.lefthalf.filled": "security-medium", "figure.run": "games-highscores",
        "gamecontroller": "applications-games", "play.tv": "media-playback-start", "briefcase": "view-financial-account",
        "person.badge.shield.checkmark": "security-high", "sparkles": "games-hint", "paperclip": "mail-attachment",
        "xmark": "window-close", "iphone.radiowaves.left.and.right": "smartphone", "iphone": "smartphone",
        "play.circle": "media-playback-start", "play": "media-playback-start", "lock.rotation": "object-locked",
        "qrcode.viewfinder": "view-barcode-qr", "qrcode": "view-barcode-qr", "square.and.pencil": "document-edit",
        "eye.slash": "view-hidden", "eye": "view-visible", "lock.shield": "security-high", "safari": "internet-services",
        "arrow.up.right.square": "internet-services", "arrow.up.forward.square": "internet-services",
        "doc.on.clipboard": "edit-paste", "key": "password-copy", "hand.raised": "security-low",
        "exclamationmark.bubble": "dialog-warning", "list.bullet.rectangle": "view-list-details",
        "arrow.uturn.backward": "edit-undo", "doc.plaintext": "document-new", "doc.richtext": "document-new",
        "paperplane.circle": "mail-send", "checkmark.seal": "emblem-checked", "clock.arrow.circlepath": "view-history", "scope": "crosshairs", "calendar.badge.clock": "view-calendar-day",
        "gauge.with.dots.needle.67percent": "office-chart-pie", "sum": "accessories-calculator", "slider.horizontal.3": "configure", "info.circle": "help-about", "ellipsis.circle": "overflow-menu",
        // SymbolPicker catalogue (SymbolCatalog.sections) – closest Breeze icon
        "dollarsign": "view-currency-list", "wallet.bifold": "wallet-open", "percent": "format-number-percent",
        "giftcard": "view-financial-account-asset", "basket": "view-financial-category-expense", "cup.and.saucer": "food",
        "lightbulb": "flashlight-on", "flame": "flameshot-tray", "drop": "draw-watercolor", "wifi": "network-wireless",
        "phone": "phone", "tv": "video-television", "washer": "configure", "wrench.and.screwdriver": "tools",
        "bus": "car", "train.side.front.car": "car", "bicycle": "car", "scooter": "car",
        "airplane": "transport-mode-flight", "ferry": "transport-mode-flight", "parkingsign": "car", "figure.walk": "im-user",
        "film": "media-optical-video", "music.note": "folder-music", "book": "address-book-new", "sportscourt": "games-highscores",
        "dumbbell": "games-highscores", "tent": "weather-clear-night", "beach.umbrella": "weather-clear",
        "camera": "camera-photo", "ticket": "view-financial-list", "party.popper": "draw-star", "person.2": "system-users",
        "person.3": "system-users", "figure.and.child.holdinghands": "system-users", "figure.2.and.child.holdinghands": "system-users",
        "stroller": "im-user", "heart": "love", "birthday.cake": "food-cake", "teddybear": "applications-games",
        "graduationcap": "applications-education", "backpack": "applications-education", "pawprint": "im-user-online",
        "laptopcomputer": "computer-laptop", "tray.full": "mail-folder-inbox", "envelope": "mail-message",
        "hammer": "tools", "signature": "document-sign", "pills": "security-high", "stethoscope": "security-high",
        "heart.text.square": "love", "bandage": "security-high", "eyeglasses": "face-glasses",
        "figure.mind.and.body": "games-hint", "bed.double": "weather-clear-night", "scissors": "edit-cut",
        "umbrella": "weather-showers", "tshirt": "view-financial-category-expense", "star": "starred", "flag": "flag",
        "cloud": "weather-overcast", "questionmark.circle": "dialog-question",
        // rule editor / category menu
        "arrow.turn.down.right": "go-next", "arrow.up.to.line": "go-top", "pause": "media-playback-pause",
        "plus.circle": "list-add",
        "bolt.slash": "dialog-cancel", "xmark.octagon": "dialog-error", "camera.viewfinder": "camera-photo",
        // settings & recurring dialogs
        "keyboard": "help-keybord-shortcuts", "network": "network-wired", "flag.checkered": "flag",
        "ladybug": "tools-report-bug", "bubble.left.and.bubble.right": "dialog-messages", "hand.point.up.left": "transform-browse",
        "list.bullet.clipboard": "view-list-text", "checkmark.shield": "security-high", "circle": "draw-circle",
        "minus.circle": "list-remove", "arrow.clockwise": "view-refresh", "diamond": "view-financial-account-asset", "creditcard.fill": "view-financial-account-credit-card",
        // filled variants (SyncLog outcome, RecurringSheet): Breeze has no filled circles, same icon as the outline
        "checkmark.circle.fill": "dialog-ok-apply", "exclamationmark.triangle.fill": "dialog-warning", "minus.circle.fill": "list-remove",
        // Tresor sichern (VaultBackupUI), RAH-10 key file (Rah10AddForm)
        "externaldrive.badge.plus": "document-save-all", "doc.badge.key": "document-encrypt",
        // booking list and inspector (tags #228, merchant list #495, category menu #366)
        "number": "tag-assigned", "storefront": "view-financial-category-expense", "tag.slash": "tag-delete",
        "xmark.circle.fill": "window-close", "plus.circle.fill": "list-add",
        // MerchantLogoTip (#33)
        "photo.on.rectangle": "insert-image"
    })
    function icon(name) {
        if (!name) return "tag"
        if (map[name]) return map[name]
        const base = name.replace(/\.(fill|circle|square|badge.*)$/g, "").replace(/\.(fill|circle)$/, "")
        if (map[base]) return map[base]
        const head = name.split(".")[0]
        return map[head] || "tag"
    }
}
