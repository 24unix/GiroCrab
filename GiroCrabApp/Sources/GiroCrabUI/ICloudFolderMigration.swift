import CryptoKit
import Foundation

/// Which iCloud Drive folder holds the sync snapshots. Older versions used a
/// different folder name; its data is COPIED (never moved or deleted) into
/// "GiroCrab" once, and only when that folder is still empty.
enum ICloudFolderMigration {
    static let folderName = "GiroCrab"
    /// Name of the former folder. Internal only, never shown in the UI.
    static let legacyFolderName = "moneymoney"

    struct Resolution: Equatable {
        /// Folder to sync with.
        var url: URL
        /// "GiroCrab" is occupied by foreign files, so the old folder stays in use: show a hint.
        var conflict: Bool
        /// Both folders hold a vault and this app did not migrate: no automatic switch, show a hint.
        var bothHaveVault = false
        /// The data was copied just now (record the time, see `legacyChanged`).
        var didMigrate = false
        /// SHA-256 (hex) of each vault file in the old folder at migration time, by file name.
        var legacyHashes: [String: String] = [:]
    }

    /// Decides the folder inside `cloudDocs` (iCloud Drive root) and migrates if due.
    /// With `create`, a new "GiroCrab" folder is created when neither exists.
    /// `migratedByThisApp`: this app copied the data before (a vault in "GiroCrab" is then its own).
    static func resolve(cloudDocs: URL, create: Bool = true, migratedByThisApp: Bool = false, fm: FileManager = .default) -> Resolution {
        let new = cloudDocs.appendingPathComponent(folderName, isDirectory: true)
        let old = cloudDocs.appendingPathComponent(legacyFolderName, isDirectory: true)
        guard SyncFolder.containsVault(old) else {
            if create { try? fm.createDirectory(at: new, withIntermediateDirectories: true) }
            return Resolution(url: new, conflict: false)
        }
        if SyncFolder.containsVault(new) {
            return migratedByThisApp
                ? Resolution(url: new, conflict: false)
                : Resolution(url: old, conflict: false, bothHaveVault: true)
        }
        if !isEmpty(new, fm) { return Resolution(url: old, conflict: true) }
        guard create else { return Resolution(url: old, conflict: false) }
        guard copy(from: old, to: new, cloudDocs: cloudDocs, fm: fm) else { return Resolution(url: old, conflict: false) }
        writeMovedMarker(in: old)
        return Resolution(url: new, conflict: false, didMigrate: true, legacyHashes: vaultHashes(in: old, fm: fm))
    }

    /// Marker the old folder gets after a successful migration. Vault files stay untouched.
    static let movedMarkerName = "GIROCRAB_MOVED.txt"
    static let movedMarkerText = """
        Die Daten dieser Synchronisierung liegen jetzt im Ordner „GiroCrab“ in iCloud Drive. Bitte aktualisieren Sie alle Geräte auf die neueste GiroCrab-Version.

        The data of this sync now lives in the “GiroCrab” folder in iCloud Drive. Please update all devices to the latest GiroCrab version.

        """

    private static func writeMovedMarker(in old: URL) {
        try? Data(movedMarkerText.utf8).write(to: old.appendingPathComponent(movedMarkerName), options: .atomic)
    }

    /// Whether the folder carries the marker (iOS: the picked folder was moved).
    static func hasMovedMarker(in dir: URL, fm: FileManager = .default) -> Bool {
        fm.fileExists(atPath: dir.appendingPathComponent(movedMarkerName).path)
    }

    /// iOS: a picked folder without a vault would get a NEW vault; the user confirms first.
    static func needsNewVaultConfirmation(_ dir: URL) -> Bool { !SyncFolder.containsVault(dir) }

    /// Name of a direct subfolder ("GiroCrab", else the former one) that holds a vault, or nil.
    /// iOS: the user picked "iCloud Drive" itself or a parent instead of the sync folder (#456).
    /// An undownloaded folder shows up as a `.<name>.icloud` placeholder and counts too.
    static func vaultSubfolder(in dir: URL, fm: FileManager = .default) -> String? {
        for name in [folderName, legacyFolderName] {
            let sub = dir.appendingPathComponent(name, isDirectory: true)
            if SyncFolder.containsVault(sub) { return name }
        }
        return nil
    }

    /// Whether the picked folder holds a vault. A folder iCloud is still listing looks empty at
    /// first: it is asked to download, and checked again for up to `wait` seconds.
    static func waitForVault(in dir: URL, wait: TimeInterval, fm: FileManager = .default) async -> Bool {
        let deadline = Date().addingTimeInterval(wait)
        while true {
            if SyncFolder.containsVault(dir) { return true }
            if Date() >= deadline { return false }
            try? fm.startDownloadingUbiquitousItem(at: dir)
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Whether `url` is the former folder (iOS: the picked folder).
    static func isLegacyFolder(_ url: URL) -> Bool { url.lastPathComponent == legacyFolderName }

    /// SHA-256 of every downloaded vault file in `dir`, by name.
    static func vaultHashes(in dir: URL, fm: FileManager = .default) -> [String: String] {
        var result: [String: String] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where SyncFolder.isSnapshotName(name) {
            if let hash = sha256(dir.appendingPathComponent(name)) { result[name] = hash }
        }
        return result
    }

    private static func sha256(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether the CONTENT of a vault file in the old folder differs from the migration
    /// (`hashes`): another device still writes there. The modification time (after `since`)
    /// is only a pre-filter, so a touched but identical file raises no notice.
    /// The old folder is only read, never changed.
    static func legacyChanged(cloudDocs: URL, since: Date, hashes: [String: String], fm: FileManager = .default) -> Bool {
        let old = cloudDocs.appendingPathComponent(legacyFolderName, isDirectory: true)
        let names = (try? fm.contentsOfDirectory(atPath: old.path)) ?? []
        return names.contains { name in
            guard SyncFolder.isSnapshotName(name) else { return false }
            let url = old.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard (modified ?? .distantPast) > since, let hash = sha256(url) else { return false }
            return hashes[name] != hash
        }
    }

    /// Finder metadata only counts as empty.
    private static func isEmpty(_ dir: URL, _ fm: FileManager) -> Bool {
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.allSatisfy { $0.hasPrefix(".") && !$0.hasSuffix(".icloud") }
    }

    /// Copies via a staging folder so "GiroCrab" is either complete or untouched.
    /// Not-yet-downloaded iCloud placeholders are requested; the copy is retried at the next start.
    private static func copy(from old: URL, to new: URL, cloudDocs: URL, fm: FileManager) -> Bool {
        guard let names = try? fm.contentsOfDirectory(atPath: old.path) else { return false }
        let placeholders = names.filter { SyncFolder.placeholderTarget($0) != nil }
        if !placeholders.isEmpty {
            for name in placeholders { try? fm.startDownloadingUbiquitousItem(at: old.appendingPathComponent(name)) }
            return false
        }
        let staging = cloudDocs.appendingPathComponent(".GiroCrab-migration-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for name in names where name != ".DS_Store" {
                try fm.copyItem(at: old.appendingPathComponent(name), to: staging.appendingPathComponent(name))
            }
            // Only an (effectively) empty target folder is replaced.
            if fm.fileExists(atPath: new.path) { try fm.removeItem(at: new) }
            try fm.moveItem(at: staging, to: new)
            return true
        } catch {
            try? fm.removeItem(at: staging)
            return false
        }
    }

    /// Folder name for the UI: the real name, also of the former folder (#909).
    /// It is the user's folder, not a text of ours, so the brand rule for UI
    /// texts does not apply; hiding it made the label "iCloud Drive / iCloud Drive".
    static func displayName(for url: URL) -> String {
        url.lastPathComponent
    }
}
