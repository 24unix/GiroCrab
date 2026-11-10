import Foundation
import Observation
import GiroCrabCore

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
    }
    private let fileName = "tresor.girocrab"
    /// Legacy plaintext key file of v0.4.0. Never written anymore; removed on sync.
    private let legacyKeyFileName = "tresor.key"
    private let defaults = UserDefaults.standard

    public var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: K.enabled)
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
        if FileManager.default.fileExists(atPath: mm.appendingPathComponent("tresor.girocrab").path) { return mm }
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

    /// - Parameters:
    ///   - remoteKey: key of the iCloud snapshot if it differs from `key`
    ///     (pasted by the user from the other device).
    ///   - mergeOnly: merge the snapshot into the local vault but don't write
    ///     it back (used while adopting a pasted key).
    public func sync(vault: Vault, localPath: String, key: Data, remoteKey: Data? = nil, mergeOnly: Bool = false) async {
        guard !isSyncing else { return }
        isSyncing = true; lastError = nil; keyMismatch = false
        defer { isSyncing = false }
        do {
            let (dir, release) = try syncDirectory()
            defer { release() }
            let local = URL(fileURLWithPath: localPath)
            let remote = dir.appendingPathComponent(fileName)
            let legacyKeyFile = dir.appendingPathComponent(legacyKeyFileName)
            let stats = try await Task.detached { [fileName] () throws -> MergeStats? in
                // Security: never leave the raw vault key next to the vault in iCloud Drive.
                Self.removeLegacyKeyFile(legacyKeyFile)
                let res = try Self.merge(vault: vault, local: local, remote: remote, key: key, remoteKey: remoteKey, mergeOnly: mergeOnly, tmpName: fileName)
                return res
            }.value
            lastSync = Date()
            defaults.set(lastSync, forKey: K.last)
            lastStats = stats.map {
                String(localized: "\($0.bookingsAdded) neue / \($0.bookingsUpdated) aktualisierte Buchungen, \($0.accountsAdded) Konten")
            } ?? String(localized: "Tresor in iCloud Drive aktualisiert")
            defaults.set(lastStats, forKey: K.stats)
        } catch {
            if (error as NSError).domain == "CloudSync", (error as NSError).code == 3 { keyMismatch = true }
            lastError = error.localizedDescription
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

    nonisolated private static func merge(vault: Vault, local: URL, remote: URL, key: Data, remoteKey: Data?, mergeOnly: Bool, tmpName: String) throws -> MergeStats? {
        let fm = FileManager.default
        var stats: MergeStats?

        if ensureDownloaded(remote) {
            let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + tmpName)
            defer { try? fm.removeItem(at: tmp) }
            try fm.copyItem(at: remote, to: tmp)
            do {
                stats = try vault.mergeOtherVault(otherPath: tmp.path, key: key)
            } catch {
                // Local key doesn't open the snapshot: only a key the user pasted can.
                if let remoteKey, remoteKey != key {
                    do {
                        stats = try vault.mergeOtherVault(otherPath: tmp.path, key: remoteKey)
                    } catch {
                        throw Self.keyMismatchError
                    }
                } else {
                    throw Self.keyMismatchError
                }
            }
        }

        try vault.checkpoint()
        if mergeOnly { return stats }

        // Nie einen leeren (frischen) Tresor über den befüllten in iCloud Drive schreiben.
        guard ((try? vault.accountCount()) ?? 0) > 0 else { return stats }
        let tmpOut = copyToTemp(local, fm)
        if fm.fileExists(atPath: remote.path) {
            _ = try fm.replaceItemAt(remote, withItemAt: tmpOut)
        } else {
            try fm.copyItem(at: tmpOut, to: remote)
            try? fm.removeItem(at: tmpOut)
        }
        return stats
    }

    nonisolated private static var keyMismatchError: NSError {
        NSError(domain: "CloudSync", code: 3, userInfo: [NSLocalizedDescriptionKey: String(localized: "Der Tresor in iCloud nutzt einen anderen Schlüssel. Aktivieren Sie den iCloud-Schlüsselbund oder fügen Sie den Tresor-Schlüssel von Ihrem anderen Gerät ein (Einstellungen › iCloud Sync).")])
    }

    nonisolated private static func ensureDownloaded(_ remote: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: remote.path) {
            try? fm.startDownloadingUbiquitousItem(at: remote)
            return true
        }
        let placeholder = remote.deletingLastPathComponent().appendingPathComponent("." + remote.lastPathComponent + ".icloud")
        guard fm.fileExists(atPath: placeholder.path) else { return false }
        try? fm.startDownloadingUbiquitousItem(at: remote)
        for _ in 0..<120 {
            if fm.fileExists(atPath: remote.path) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    nonisolated private static func copyToTemp(_ src: URL, _ fm: FileManager) -> URL {
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? fm.copyItem(at: src, to: tmp)
        return tmp
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
