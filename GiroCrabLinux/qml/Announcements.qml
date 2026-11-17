pragma Singleton
import QtQuick
import QtCore

// Announcements.swift › AnnouncementCenter: quiet project news ("Mitteilungen").
// Verification, parsing and the filter for this build happen in src/announcements.rs;
// the state the Mac keeps in UserDefaults (`announcements.enabled`, `.dismissed`, `.json`,
// `.signature`, `.lastCheck`) is stored here in GiroCrab.conf, section [announcements].
QtObject {
    id: center

    property Settings store: Settings {
        category: "announcements"
        /// On by default: project news, not marketing, and the banner is quiet; the one
        /// switch turns the whole thing (and the network request) off.
        property bool enabled: true
        /// JSON array of dismissed ids (a dismissed announcement never comes back).
        property string dismissed: "[]"
        /// The last verified file and its signature (base64).
        property string json: ""
        property string signature: ""
        /// Time of the last successful download (ms since 1970).
        property real lastCheck: 0
    }

    readonly property bool isEnabled: store.enabled
    function setEnabled(on) {
        store.enabled = on
        if (on) refresh(false)
    }

    /// { sequence, announcements: [{ id, severity, from_ms, until_ms, title, summary, body, link }] }
    property var document: null
    property var dismissedIDs: {
        try { const a = JSON.parse(store.dismissed); return Array.isArray(a) ? a : [] } catch (e) { return [] }
    }
    /// Clock for the from/until window; ticks hourly.
    property real now: Date.now()
    property Timer clock: Timer { interval: 60 * 60 * 1000; repeat: true; running: true; onTriggered: center.now = Date.now() }

    /// `all`: everything that applies to this build right now, dismissed or not.
    readonly property var all: {
        if (!isEnabled || !document) return []
        return document.announcements.filter(a => !(a.from_ms !== null && now < a.from_ms)
                                                 && !(a.until_ms !== null && now > a.until_ms))
    }
    /// `banner`: the first one not yet dismissed.
    readonly property var banner: {
        for (const a of all) if (dismissedIDs.indexOf(a.id) < 0) return a
        return null
    }

    function dismiss(a) {
        if (dismissedIDs.indexOf(a.id) >= 0) return
        const ids = dismissedIDs.concat([a.id]).sort()
        store.dismissed = JSON.stringify(ids)
        dismissedIDs = ids
    }

    /// `loadStored`
    Component.onCompleted: {
        if (!store.json) return
        try { document = AppModel.core("announcements_load", { json: store.json, signature: store.signature }) }
        catch (e) { document = null }
    }

    /// Hilfe › Mitteilungen … (AnnouncementsWindow.qml)
    property bool showWindow: false

    property bool inFlight: false
    /// `refresh(force:)`: off, without key or within six hours of the last check nothing
    /// happens (decided in Rust, on a worker thread). Failures stay silent.
    function refresh(force) {
        if (!isEnabled || inFlight) return
        inFlight = true
        AppModel.coreAsync("announcements_refresh", { enabled: isEnabled, force: !!force, last_check_ms: store.lastCheck || null }, r => {
            inFlight = false
            now = Date.now()
            if (!r.fetched) return
            store.lastCheck = Date.now()
            // `accept`: verified, and a lower sequence than the stored one is a rollback
            const doc = r.document
            if (!doc || (document && doc.sequence < document.sequence)) return
            document = doc
            store.json = r.json
            store.signature = r.signature
        }, err => { inFlight = false })
    }
}
