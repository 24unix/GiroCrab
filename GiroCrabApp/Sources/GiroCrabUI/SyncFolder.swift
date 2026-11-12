import Foundation
import GiroCrabCore

/// The files in the sync folder, one snapshot per device:
/// `tresor-<device-id>.girocrab`. A device writes only its own file and
/// merges everyone else's, so two devices never overwrite each other.
/// The single `tresor.girocrab` of older versions is still read, and written
/// too during the transition, so a device on an older version keeps syncing.
struct SyncFolder: Sendable {
    static let legacyName = "tresor.girocrab"
    private static let devicePattern = #"^tresor-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.girocrab$"#

    let dir: URL
    let deviceID: String
    /// Whether a file's data is on this device; replaceable in tests.
    var isDownloaded: @Sendable (URL) -> Bool = SyncFolder.isLocal

    var ownURL: URL { dir.appendingPathComponent("tresor-\(deviceID).girocrab") }
    private var legacyURL: URL { dir.appendingPathComponent(Self.legacyName) }

    /// Exact names only: iCloud's conflict copies ("tresor-… 2.girocrab")
    /// and anything else in the folder are left alone.
    private static func isSnapshotName(_ name: String) -> Bool {
        name == legacyName || name.range(of: devicePattern, options: .regularExpression) != nil
    }

    /// Name of the file an iCloud placeholder (`.name.icloud`) stands for.
    private static func placeholderTarget(_ name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return nil }
        return String(name.dropFirst().dropLast(".icloud".count))
    }

    /// Whether the folder already holds a vault (downloaded or not).
    static func containsVault(_ dir: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.contains { isSnapshotName(placeholderTarget($0) ?? $0) }
    }

    /// Why the folder can't be listed (e.g. macOS hasn't granted access to
    /// iCloud Drive), or nil. Without this, an unreadable folder looks
    /// exactly like an empty one.
    func accessError() -> Error? {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            return nil
        } catch {
            return error
        }
    }

    /// Snapshot files of the other devices that are on disk. Files iCloud
    /// hasn't downloaded yet are requested and left for the next round.
    func peers() -> [URL] {
        scan().ready
    }

    /// Waits up to `timeout` for peer snapshots iCloud is still downloading,
    /// for a sync someone is waiting for (e.g. the first one on a new device).
    func waitForDownloads(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while scan().pending, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// Peers ready to read, and whether any is still being downloaded.
    /// Not downloaded means an `.icloud` placeholder (older iCloud Drive) or
    /// a file under its real name without its data (File Provider); reading
    /// such a file would block until iCloud has fetched it.
    private func scan() -> (ready: [URL], pending: Bool) {
        let fm = FileManager.default
        let own = ownURL.lastPathComponent
        var ready: [URL] = []
        var pending = false
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let target = Self.placeholderTarget(name) ?? name
            guard Self.isSnapshotName(target), target != own else { continue }
            let url = dir.appendingPathComponent(target)
            if name == target, isDownloaded(url) {
                ready.append(url)
            } else if name != target, fm.fileExists(atPath: url.path) {
                continue // placeholder left next to the downloaded file
            } else {
                try? fm.startDownloadingUbiquitousItem(at: url)
                pending = true
            }
        }
        return (ready.sorted { $0.lastPathComponent < $1.lastPathComponent }, pending)
    }

    /// Whether iCloud has the file's data on this device (true outside iCloud).
    static func isLocal(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        guard let status = values?.ubiquitousItemDownloadingStatus else { return true }
        return status != .notDownloaded
    }

    /// Peers whose modification date differs from the one last merged.
    func changedPeers(seen: [String: Double]) -> [URL] {
        peers().filter { Self.modified($0) != seen[$0.lastPathComponent] }
    }

    private static func modified(_ url: URL) -> Double? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970
    }

    /// Merges each peer into `vault`. A peer that this vault's key doesn't
    /// open is tried with `remoteKey` (pasted from the other device), else
    /// reported as `keyMismatch`; the other peers are merged either way.
    func merge(vault: Vault, peers: [URL], remoteKey: Data?) -> SyncMergeResult {
        var result = SyncMergeResult()
        let fm = FileManager.default
        for url in peers {
            let name = url.lastPathComponent
            let modified = Self.modified(url)
            let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + name)
            defer {
                for suffix in ["", "-wal", "-shm"] {
                    try? fm.removeItem(atPath: tmp.path + suffix)
                }
            }
            do {
                // Merge a private copy: opening the vault migrates it in place.
                try Self.coordinate(reading: url) { try fm.copyItem(at: $0, to: tmp) }
                do {
                    result.stats.append(try vault.mergePeerSnapshot(otherPath: tmp.path))
                } catch CoreError.WrongKey {
                    guard let remoteKey else { throw CoreError.WrongKey }
                    result.stats.append(try vault.mergeOtherVault(otherPath: tmp.path, key: remoteKey))
                }
            } catch CoreError.WrongKey {
                result.keyMismatch = true
                if let modified { result.failed[name] = modified }
                continue
            } catch {
                result.errors.append("\(name): \(error.localizedDescription)")
                continue
            }
            if let modified { result.seen[name] = modified }
        }
        return result
    }

    /// Writes this device's snapshot. The transition file `tresor.girocrab`
    /// is replaced only when it is absent or its current version was merged
    /// (`merged`: name → modification date), so a file this device couldn't
    /// read (other key, error, still downloading) is never overwritten.
    /// Writes nothing when the vault never had an account, so a fresh vault never
    /// replaces a filled one.
    @discardableResult
    func write(vault: Vault, merged: [String: Double] = [:]) throws -> SyncWrite {
        guard try vault.hasAccountHistory() else { return SyncWrite() }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".girocrab")
        defer { try? fm.removeItem(at: tmp) }
        try vault.writeSnapshot(destPath: tmp.path)
        try Self.replace(ownURL, with: tmp)
        var result = SyncWrite(wrote: true)
        if legacyMayBeReplaced(merged: merged) {
            // Best effort: the own file is what this device's peers read.
            if (try? Self.replace(legacyURL, with: tmp)) != nil {
                result.legacyModified = Self.modified(legacyURL)
            }
        }
        return result
    }

    private func legacyMayBeReplaced(merged: [String: Double]) -> Bool {
        let fm = FileManager.default
        let placeholder = dir.appendingPathComponent(".\(Self.legacyName).icloud")
        if fm.fileExists(atPath: legacyURL.path) {
            return isDownloaded(legacyURL) && Self.modified(legacyURL) == merged[Self.legacyName]
        }
        return !fm.fileExists(atPath: placeholder.path)
    }

    /// Puts a copy of `snapshot` at `target` inside a coordinated write.
    private static func replace(_ target: URL, with snapshot: URL) throws {
        let fm = FileManager.default
        let copy = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".girocrab")
        try fm.copyItem(at: snapshot, to: copy)
        defer { try? fm.removeItem(at: copy) }
        try coordinate(writing: target) { url in
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: copy)
            } else {
                try fm.moveItem(at: copy, to: url)
            }
        }
    }

    private static func coordinate(reading url: URL, _ body: (URL) throws -> Void) throws {
        var coordError: NSError?
        var bodyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            do { try body(u) } catch { bodyError = error }
        }
        if let e = coordError ?? bodyError { throw e }
    }

    private static func coordinate(writing url: URL, _ body: (URL) throws -> Void) throws {
        var coordError: NSError?
        var bodyError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { u in
            do { try body(u) } catch { bodyError = error }
        }
        if let e = coordError ?? bodyError { throw e }
    }
}

struct SyncMergeResult: Sendable {
    var stats: [MergeStats] = []
    /// File name → modification date (seconds since 1970) of each peer merged.
    var seen: [String: Double] = [:]
    /// Peers this vault's key doesn't open: skipped by automatic sync
    /// until they change, but never counted as merged.
    var failed: [String: Double] = [:]
    var keyMismatch = false
    var errors: [String] = []
}

struct SyncWrite: Sendable {
    var wrote = false
    /// Modification date of the transition file when it was written too.
    var legacyModified: Double?
}
