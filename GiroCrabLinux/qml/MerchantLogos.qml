pragma Singleton
import QtQuick
import QtCore
import GiroCrab

// AppModel+Logos.swift: merchant logos from the internet (Tier 2, GitHub #33), plus the
// `logoProvider` state of AppModel.swift and MerchantLogoTip.swift's persistence.
// Privacy: nothing is requested while the provider is "off" (the default, also in the
// demo vault); the core gates cached and fetched logos on the same setting (#422).
QtObject {
    id: logos

    /// AppModel.logoProvider: "off", "duckduckgo" or "google", as stored in the open vault.
    property string provider: "off"
    /// AppModel.onlineLogos
    readonly property bool onlineLogos: provider !== "off"
    /// Bumped whenever logos arrive or the cache changes: signets re-read through it.
    property int version: 0
    /// AppModel.logoVersion + cache resets: part of every signet's task id, so a changed
    /// domain or a cleared cache makes the signets on screen ask again.
    property int epoch: 0

    /// logoCache: candidate key → { url: "data:…", pixels } | null (nothing found). Only
    /// the logos of merchants shown so far; dropped with the vault.
    property var cache: ({})
    /// logoInflight: candidate keys being loaded (one request per merchant at a time).
    property var inflight: ({})
    /// Waiting requests; at most `maxRunning` worker threads ask the core at once, so a
    /// fast scroll over many new merchants does not start a thread per row.
    property var queue: []
    property int running: 0
    readonly property int maxRunning: 4

    // MARK: provider (AppModel+Connections.swift › reloadSettings: `onlineLogoProvider()`)
    function reloadProvider() {
        let p = "off"
        if (AppModel.settings.length > 0) {
            try { p = AppModel.core("online_logo_provider") } catch (e) { p = "off" }
        }
        if (p === provider) return
        provider = p
        // a logo not found with the previous provider may exist with this one
        const kept = {}
        for (const k in cache) if (cache[k] !== null) kept[k] = cache[k]
        cache = kept
        queue = []
        inflight = ({})
        epoch++
        version++
        if (onlineLogos) tipDone = true // MerchantLogoTipEligibility: answered for good
    }
    /// MerchantLogoSettingsSection / MerchantLogoTip: stores the choice in the vault;
    /// `provider` follows once the core has stored it.
    function setProvider(value) { AppModel.saveSetting("merchants.online_logos", value) }

    property Connections appModel: Connections {
        target: AppModel
        function onSettingsChanged() { logos.reloadProvider() }
        // another vault in front: nothing of the previous one may appear
        function onVaultGenerationChanged() { logos.reset() }
    }

    // MARK: logos
    /// logoCandidates
    function candidates(merchant) {
        if (!merchant) return []
        const c = merchant.domain_candidates || []
        return c.length === 0 && merchant.domain ? [merchant.domain] : c
    }
    function key(merchant) { return candidates(merchant).join("|") }

    /// cachedLogo(for:): `{ url, pixels }` once loaded; null while online logos are off
    /// (the in-memory cache stays, so switching back on shows the logos at once).
    function cachedLogo(merchant) {
        if (!onlineLogos) return null
        const k = key(merchant)
        return k !== "" ? (cache[k] || null) : null
    }

    /// logo(for:): loads the logo of `merchant` in the background unless it is cached or
    /// already on its way; the signets showing it pick it up through `version`.
    function request(merchant) {
        if (!onlineLogos || !AppModel.isUnlocked) return
        const c = candidates(merchant)
        if (c.length === 0) return
        const k = c.join("|")
        if (k in cache || inflight[k]) return
        inflight[k] = true
        queue.push({ key: k, candidates: c })
        pump()
    }
    function pump() {
        while (running < maxRunning && queue.length > 0) {
            const job = queue.shift(), ep = epoch
            running++
            // vault read, then (if not cached) the provider's favicon – on a worker thread
            AppModel.coreAsync("merchant_logo", { candidates: job.candidates },
                               r => finish(ep, job.key, r), () => finish(ep, job.key, null))
        }
    }
    function finish(ep, k, result) {
        running--
        if (ep === epoch) {
            delete inflight[k]
            cache[k] = result || null
            version++
        }
        pump()
    }
    function reset() {
        cache = ({}); inflight = ({}); queue = []
        epoch++
        version++
    }

    /// setMerchantDomain: manual domain from the inspector; null/empty removes the override.
    function setMerchantDomain(merchant, domain) {
        let stored
        try {
            stored = AppModel.core("set_merchant_domain", { merchant_key: merchant.key, domain: domain || null })
        } catch (e) { AppModel.errorMessage = e.message; return }
        // with online logos off, no logo will appear (#422)
        AppModel.toast = stored !== null
            ? (onlineLogos ? qsTr("Domain für %1: %2 – Logo wird geladen").arg(merchant.name).arg(stored)
                           : qsTr("Domain für %1: %2").arg(merchant.name).arg(stored))
            : qsTr("Domain-Zuordnung entfernt")
        reset()
        AppModel.reloadBookings()
    }

    function clearLogoCache() {
        try { AppModel.core("clear_logo_cache") } catch (e) { AppModel.errorMessage = e.message; return }
        reset()
        AppModel.toast = qsTr("Logo-Cache geleert")
    }

    // MARK: MerchantLogoTip (TipKit state: shown until answered or closed)
    property Settings tipState: Settings {
        id: tipSettings
        category: "tips"
        property bool merchantLogoDone: false
    }
    property alias tipDone: tipSettings.merchantLogoDone
    /// `--show-tips` (LaunchOptions.showTips): tips also in the demo vault, state reset.
    readonly property bool showTips: AppModel.launchArgs.indexOf("--show-tips") >= 0
    Component.onCompleted: if (showTips) tipDone = false
    /// MerchantLogoTipEligibility: real (non-demo) bookings on screen, online logos off.
    readonly property bool tipEligible: !tipDone && provider === "off" && AppModel.isUnlocked
        && AppModel.dayGroups.length > 0 && (!AppModel.isDemo || showTips)
}
