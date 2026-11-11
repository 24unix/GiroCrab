import Foundation
import Observation
import SwiftUI
import GiroCrabCore
#if os(iOS)
import UIKit
#endif

@Observable @MainActor
public final class CloudSyncManager {
    public static let shared = CloudSyncManager()

    public enum Location: String { case container, folder }

    private enum K {
        static let enabled = "girocrab.sync.enabled"
        static let location = "girocrab.sync.location"
        static let bookmark = "girocrab.sync.bookmark"
        static let last = "girocrab.sync.last"
        static let stats = "girocrab.sync.stats"
        static let seen = "girocrab.sync.seen"
        static let failed = "girocrab.sync.failed"
    }
    /// Legacy plaintext key file of v0.4.0. Never written anymore; removed on sync.
    private let legacyKeyFileName = "tresor.key"
    private let defaults = UserDefaults.standard
    /// Modification date of each peer snapshot when it was last merged.
    @ObservationIgnored private var seen: [String: Double]
    /// Same for peers this vault's key didn't open (not retried until they change).
    @ObservationIgnored private var failed: [String: Double]
    @ObservationIgnored private var cachedDeviceID: String?
    @ObservationIgnored private var folderOverride: URL?

    public var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: K.enabled)
            if !isEnabled { stopAutoSync() }
            #if os(macOS)
            if isEnabled && folderName == nil {
                ensureDefaultMacICloudFolder()
            }
            #endif
        }
    }
    public var location: Location { didSet { defaults.set(location.rawValue, forKey: K.location) } }
    public private(set) var folderName: String?
    public private(set) var lastSync: Date?
    public private(set) var lastStats: String?
    public private(set) var isSyncing = false
    public private(set) var lastError: String?
    public private(set) var keyMismatch = false

    private init() {
        isEnabled = defaults.bool(forKey: K.enabled)
        location = .folder
        lastSync = defaults.object(forKey: K.last) as? Date
        lastStats = defaults.string(forKey: K.stats)
        seen = defaults.dictionary(forKey: K.seen) as? [String: Double] ?? [:]
        failed = defaults.dictionary(forKey: K.failed) as? [String: Double] ?? [:]
        if let url = try? resolveBookmark() {
            folderName = url.lastPathComponent
        } else if isEnabled {
            // Only touch iCloud Drive when the user has actually enabled sync.
            #if os(macOS)
            ensureDefaultMacICloudFolder()
            #endif
        }
    }

    public var containerAvailable: Bool { false }

    #if os(macOS)
    private var defaultMacICloudURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cloudDocs = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: cloudDocs.path) else { return nil }
        let mm = cloudDocs.appendingPathComponent("moneymoney", isDirectory: true)
        if SyncFolder.containsVault(mm) { return mm }
        let dir = cloudDocs.appendingPathComponent("GiroCrab", isDirectory: true)
        // Only reached once sync is enabled (init / isEnabled / sync call it gated).
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func ensureDefaultMacICloudFolder() {
        if let dir = defaultMacICloudURL {
            _ = try? setFolder(dir)
            folderName = "iCloud Drive / " + dir.lastPathComponent
        }
    }
    #endif

    public func setFolder(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(data, forKey: K.bookmark)
        }
        folderName = url.lastPathComponent
        location = .folder
        lastError = nil
    }

    /// Merges the other devices' snapshots into `vault`, then writes this
    /// device's own snapshot. Uses the open vault's key: no keychain prompt.
    /// - Parameters:
    ///   - remoteKey: key pasted from another device, for snapshots this
    ///     vault's key doesn't open.
    ///   - mergeOnly: merge but don't write (used while adopting a pasted key).
    public func sync(vault: Vault, remoteKey: Data? = nil, mergeOnly: Bool = false) async {
        guard !isSyncing else { return }
        isSyncing = true; lastError = nil; keyMismatch = false
        defer { isSyncing = false }
        do {
            let (dir, release) = try syncDirectory()
            defer { release() }
            let folder = SyncFolder(dir: dir, deviceID: deviceID)
            let legacyKeyFile = dir.appendingPathComponent(legacyKeyFileName)
            let seen = self.seen
            let (result, written) = try await Task.detached { () throws -> (SyncMergeResult, SyncWrite) in
                // Security: never leave the raw vault key next to the vault in iCloud Drive.
                Self.removeLegacyKeyFile(legacyKeyFile)
                // Someone is waiting for this sync: give iCloud time to download.
                folder.waitForDownloads(timeout: 30)
                let r = folder.merge(vault: vault, peers: folder.peers(), remoteKey: remoteKey)
                let w = mergeOnly ? SyncWrite() : try folder.write(vault: vault, merged: seen.merging(r.seen) { $1 })
                return (r, w)
            }.value
            record(result, written)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Stores what a merge did: last sync time and summary, the peers'
    /// modification dates, a key mismatch or per-file errors.
    private func record(_ result: SyncMergeResult, _ written: SyncWrite = SyncWrite()) {
        seen.merge(result.seen) { $1 }
        if let m = written.legacyModified { seen[SyncFolder.legacyName] = m }
        failed.merge(result.failed) { $1 }
        for name in result.seen.keys { failed[name] = nil }
        defaults.set(seen, forKey: K.seen)
        defaults.set(failed, forKey: K.failed)
        lastSync = Date()
        defaults.set(lastSync, forKey: K.last)
        if result.stats.isEmpty {
            lastStats = String(localized: "Tresor in iCloud Drive aktualisiert")
        } else {
            let added = result.stats.reduce(UInt32(0)) { $0 + $1.bookingsAdded }
            let updated = result.stats.reduce(UInt32(0)) { $0 + $1.bookingsUpdated }
            let accounts = result.stats.reduce(UInt32(0)) { $0 + $1.accountsAdded }
            lastStats = String(localized: "\(added) neue / \(updated) aktualisierte Buchungen, \(accounts) Konten")
        }
        defaults.set(lastStats, forKey: K.stats)
        if result.keyMismatch {
            keyMismatch = true
            lastError = Self.keyMismatchError.localizedDescription
        } else if !result.errors.isEmpty {
            lastError = result.errors.joined(separator: "\n")
        }
    }

    /// This installation's id in the sync folder's file names.
    private var deviceID: String {
        if let cachedDeviceID { return cachedDeviceID }
        let id = SyncDeviceID.current(defaults: defaults, hardwareID: SyncDeviceID.hardwareID())
        cachedDeviceID = id
        return id
    }

    /// Tests point the manager at a temporary folder; nil restores the user's.
    func setFolderForTesting(_ url: URL?) {
        folderOverride = url
    }

    // MARK: automatic sync

    @ObservationIgnored private var autoVault: Vault?
    @ObservationIgnored private var onMerged: (@MainActor () -> Void)?
    @ObservationIgnored private var autoState = AutoSyncState()
    @ObservationIgnored private var autoTask: Task<Void, Never>?
    @ObservationIgnored private var autoBusy = false

    /// Keeps `vault` in sync while the app runs: writes this device's
    /// snapshot after local changes and merges other devices' snapshots
    /// when they change. `onMerged` runs after a merge that brought changes.
    public func startAutoSync(vault: Vault, onMerged: @escaping @MainActor () -> Void) {
        stopAutoSync()
        guard isEnabled else { return }
        autoVault = vault
        self.onMerged = onMerged
        autoState = AutoSyncState()
        startLoop()
    }

    /// Ends automatic sync; with `flushing`, a pending local change is
    /// written first (e.g. when the vault gets locked).
    public func stopAutoSync(flushing: Bool = false) {
        autoTask?.cancel()
        autoTask = nil
        if flushing, let vault = autoVault {
            Task { await flush(vault) }
        }
        autoVault = nil
        onMerged = nil
    }

    /// The app came to the front or went to the background.
    public func sceneChanged(_ phase: ScenePhase) {
        guard autoVault != nil else { return }
        switch phase {
        case .active:
            autoState.pollSoon()
            if autoTask == nil { startLoop() }
            Task { await autoTick() }
        #if os(iOS)
        case .background:
            // iOS suspends the app: write what's pending, then stop until it's back.
            autoTask?.cancel()
            autoTask = nil
            guard let vault = autoVault else { return }
            let id = UIApplication.shared.beginBackgroundTask(withName: "GiroCrab sync")
            Task {
                await flush(vault)
                UIApplication.shared.endBackgroundTask(id)
            }
        #endif
        default:
            break
        }
    }

    private func startLoop() {
        autoTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.autoTick()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func flush(_ vault: Vault) async {
        _ = autoState.tick(changeCount: vault.changeCount(), now: Date())
        guard autoState.hasPendingWrite else { return }
        await run(vault: vault, write: true, poll: false)
    }

    private func autoTick() async {
        guard let vault = autoVault, !isSyncing, !autoBusy else { return }
        let actions = autoState.tick(changeCount: vault.changeCount(), now: Date())
        guard !actions.isEmpty else { return }
        await run(vault: vault, write: actions.contains(.write), poll: actions.contains(.poll))
    }

    private func run(vault: Vault, write: Bool, poll: Bool) async {
        guard !autoBusy, let (dir, release) = try? syncDirectory() as (URL, () -> Void) else { return }
        autoBusy = true
        defer { autoBusy = false; release() }
        let folder = SyncFolder(dir: dir, deviceID: deviceID)
        let seen = self.seen
        let skip = seen.merging(failed) { $1 }
        let count = vault.changeCount()
        let outcome = await Task.detached { () -> (written: SyncWrite, merge: SyncMergeResult?, error: String?) in
            var written = SyncWrite()
            var error: String?
            if write {
                do { written = try folder.write(vault: vault, merged: seen) } catch let e { error = e.localizedDescription }
            }
            var merge: SyncMergeResult?
            if poll {
                let changed = folder.changedPeers(seen: skip)
                if !changed.isEmpty { merge = folder.merge(vault: vault, peers: changed, remoteKey: nil) }
            }
            return (written, merge, error)
        }.value
        if outcome.written.wrote {
            autoState.wrote(changeCount: count)
            if let m = outcome.written.legacyModified {
                self.seen[SyncFolder.legacyName] = m
                defaults.set(self.seen, forKey: K.seen)
            }
            lastSync = Date()
            defaults.set(lastSync, forKey: K.last)
        }
        if let error = outcome.error { lastError = error }
        if let merge = outcome.merge {
            autoState.merged(changes: merge.stats.reduce(UInt64(0)) { $0 + $1.changes })
            lastError = nil
            record(merge)
            let changed = merge.stats.contains {
                $0.accountsAdded + $0.categoriesAdded + $0.rulesAdded + $0.bookingsAdded + $0.bookingsUpdated + $0.groupsUpdated > 0
            }
            if changed { onMerged?() }
        }
    }

    /// Deletes `tresor.key` (and its iCloud placeholder) from the sync folder.
    nonisolated private static func removeLegacyKeyFile(_ keyFile: URL) {
        let fm = FileManager.default
        let placeholder = keyFile.deletingLastPathComponent()
            .appendingPathComponent("." + keyFile.lastPathComponent + ".icloud")
        for url in [keyFile, placeholder] where fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }
    }

    nonisolated private static var keyMismatchError: NSError {
        NSError(domain: "CloudSync", code: 3, userInfo: [NSLocalizedDescriptionKey: String(localized: "Der Tresor in iCloud nutzt einen anderen Schlüssel. Aktivieren Sie den iCloud-Schlüsselbund oder fügen Sie den Tresor-Schlüssel von Ihrem anderen Gerät ein (Einstellungen › iCloud Sync).")])
    }

    private func resolveBookmark() throws -> URL? {
        guard let data = defaults.data(forKey: K.bookmark) else { return nil }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
            return url
        }
        defaults.removeObject(forKey: K.bookmark)
        return nil
    }

    private func syncDirectory() throws -> (URL, () -> Void) {
        if let folderOverride { return (folderOverride, {}) }
        if let url = try resolveBookmark() {
            let ok = url.startAccessingSecurityScopedResource()
            #if os(macOS)
            if !ok && !FileManager.default.isReadableFile(atPath: url.path), let dir = defaultMacICloudURL {
                defaults.removeObject(forKey: K.bookmark)
                folderName = "iCloud Drive / " + dir.lastPathComponent
                return (dir, {})
            }
            #endif
            return (url, { if ok { url.stopAccessingSecurityScopedResource() } })
        }
        #if os(macOS)
        if let dir = defaultMacICloudURL {
            folderName = "iCloud Drive / " + dir.lastPathComponent
            return (dir, {})
        }
        #endif
        throw NSError(domain: "CloudSync", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "Bitte einmalig den Ordner „GiroCrab“ in iCloud Drive auswählen.")])
    }
}
