import XCTest
@testable import GiroCrabUI

/// iCloud Drive folder: new installs use "GiroCrab"; the former folder is copied once, never touched.
final class ICloudFolderMigrationTests: XCTestCase {
    private var root: URL!
    let fm = FileManager.default
    private var old: URL { root.appendingPathComponent(ICloudFolderMigration.legacyFolderName) }
    private var new: URL { root.appendingPathComponent(ICloudFolderMigration.folderName) }
    private let snapshot = "tresor-01234567-89ab-cdef-0123-456789abcdef.girocrab"

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("icloud-mig-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? fm.removeItem(at: root) }

    private func put(_ name: String, in dir: URL, _ text: String = "x") throws {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    private func requireSnapshotName() throws {
        try put(snapshot, in: root.appendingPathComponent("probe"))
        try XCTSkipUnless(SyncFolder.containsVault(root.appendingPathComponent("probe")), "snapshot name pattern changed")
        try fm.removeItem(at: root.appendingPathComponent("probe"))
    }

    func test_fresh_install_uses_new_folder() {
        let r = ICloudFolderMigration.resolve(cloudDocs: root)
        XCTAssertEqual(r.url.lastPathComponent, "GiroCrab")
        XCTAssertFalse(r.conflict)
        XCTAssertTrue(fm.fileExists(atPath: new.path))
        XCTAssertFalse(fm.fileExists(atPath: old.path))
    }

    func test_migration_copies_and_keeps_old() throws {
        try requireSnapshotName()
        try put(snapshot, in: old, "data")
        let r = ICloudFolderMigration.resolve(cloudDocs: root)
        XCTAssertEqual(r.url.lastPathComponent, "GiroCrab")
        XCTAssertFalse(r.conflict)
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent(snapshot), encoding: .utf8), "data")
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent(snapshot), encoding: .utf8), "data")
        // no staging leftovers
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path).sorted(), ["GiroCrab", "moneymoney"])
    }

    func test_migration_into_empty_existing_target() throws {
        try requireSnapshotName()
        try put(snapshot, in: old)
        try put(".DS_Store", in: new)
        let r = ICloudFolderMigration.resolve(cloudDocs: root)
        XCTAssertEqual(r.url, new)
        XCTAssertTrue(fm.fileExists(atPath: new.appendingPathComponent(snapshot).path))
    }

    func test_target_with_foreign_files_keeps_old_and_flags_conflict() throws {
        try requireSnapshotName()
        try put(snapshot, in: old)
        try put("foreign.txt", in: new)
        let r = ICloudFolderMigration.resolve(cloudDocs: root)
        XCTAssertEqual(r.url, old)
        XCTAssertTrue(r.conflict)
        XCTAssertTrue(fm.fileExists(atPath: new.appendingPathComponent("foreign.txt").path))
        XCTAssertTrue(fm.fileExists(atPath: old.appendingPathComponent(snapshot).path))
        XCTAssertFalse(fm.fileExists(atPath: new.appendingPathComponent(snapshot).path))
    }

    func test_target_already_migrated_is_used_without_notice() throws {
        try requireSnapshotName()
        try put(snapshot, in: old, "old")
        try put(snapshot, in: new, "new")
        let r = ICloudFolderMigration.resolve(cloudDocs: root, migratedByThisApp: true)
        XCTAssertEqual(r, .init(url: new, conflict: false))
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent(snapshot), encoding: .utf8), "new")
    }

    func test_missing_old_folder_uses_new() throws {
        try put("foreign.txt", in: new)
        let r = ICloudFolderMigration.resolve(cloudDocs: root)
        XCTAssertEqual(r, .init(url: new, conflict: false))
    }

    func test_old_folder_without_vault_is_ignored() throws {
        try put("notes.txt", in: old)
        XCTAssertEqual(ICloudFolderMigration.resolve(cloudDocs: root).url, new)
    }

    /// The real folder name, also for the former one (#909): "iCloud Drive / iCloud Drive"
    /// said nothing about where the vault lies. A user's folder name is not a text of
    /// ours, so the brand rule for UI texts does not apply to it.
    func test_ui_name_is_the_real_folder_name() {
        XCTAssertEqual(ICloudFolderMigration.displayName(for: old), ICloudFolderMigration.legacyFolderName)
        XCTAssertEqual(ICloudFolderMigration.displayName(for: new), "GiroCrab")
    }
}

/// Writes into the old folder after the migration (a device on an older app version).
extension ICloudFolderMigrationTests {
    private var snap: String { "tresor-01234567-89ab-cdef-0123-456789abcdef.girocrab" }

    func test_migration_reports_didMigrate_only_when_copied() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("icloud-mig2-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent("moneymoney")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: old.appendingPathComponent(snap))
        let first = ICloudFolderMigration.resolve(cloudDocs: root)
        XCTAssertTrue(first.didMigrate)
        XCTAssertEqual(first.legacyHashes.keys.sorted(), [snap])
        XCTAssertEqual(first.legacyHashes[snap]?.count, 64)
        XCTAssertFalse(ICloudFolderMigration.resolve(cloudDocs: root).didMigrate)
    }

    func test_old_folder_selected_is_recognised_for_ios_hint() {
        XCTAssertTrue(ICloudFolderMigration.isLegacyFolder(URL(fileURLWithPath: "/x/moneymoney")))
        XCTAssertFalse(ICloudFolderMigration.isLegacyFolder(URL(fileURLWithPath: "/x/GiroCrab")))
    }

    func test_legacy_change_detected_after_migration() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("icloud-mig3-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent("moneymoney")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        let file = old.appendingPathComponent(snap)
        try Data("a".utf8).write(to: file)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -100)], ofItemAtPath: file.path)
        XCTAssertTrue(ICloudFolderMigration.resolve(cloudDocs: root).didMigrate)
        let migrated = Date()
        let hashes = ICloudFolderMigration.vaultHashes(in: old)
        // untouched since the migration: no notice, and our own copy never touches the old folder
        XCTAssertFalse(ICloudFolderMigration.legacyChanged(cloudDocs: root, since: migrated, hashes: hashes))
        // an older device writes the snapshot
        // touched, content identical (e.g. iCloud re-download): no notice
        try fm.setAttributes([.modificationDate: migrated.addingTimeInterval(60)], ofItemAtPath: file.path)
        XCTAssertFalse(ICloudFolderMigration.legacyChanged(cloudDocs: root, since: migrated, hashes: hashes))
        // content changed
        try Data("changed".utf8).write(to: file)
        XCTAssertTrue(ICloudFolderMigration.legacyChanged(cloudDocs: root, since: migrated, hashes: hashes))
        // other files (not vault snapshots) are ignored; the old folder stays as it was
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -100)], ofItemAtPath: file.path)
        try Data("n".utf8).write(to: old.appendingPathComponent("notes.txt"))
        XCTAssertFalse(ICloudFolderMigration.legacyChanged(cloudDocs: root, since: migrated, hashes: hashes))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: old.path).sorted(), ["GIROCRAB_MOVED.txt", "notes.txt", snap])
    }

    func test_legacy_check_without_old_folder_is_false() {
        XCTAssertFalse(ICloudFolderMigration.legacyChanged(cloudDocs: fm.temporaryDirectory.appendingPathComponent(UUID().uuidString), since: .distantPast, hashes: [:]))
    }
}

/// Moved marker, both-folders conflict, iOS decisions.
extension ICloudFolderMigrationTests {
    private func makeRoot() throws -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent("icloud-mig4-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("moneymoney"), withIntermediateDirectories: true)
        addTeardownBlock { [fm] in try? fm.removeItem(at: root) }
        return root
    }

    private var snapName: String { "tresor-01234567-89ab-cdef-0123-456789abcdef.girocrab" }

    func test_marker_written_after_migration_and_vault_files_untouched() throws {
        let root = try makeRoot()
        let old = root.appendingPathComponent("moneymoney"), new = root.appendingPathComponent("GiroCrab")
        let file = old.appendingPathComponent(snapName)
        try Data("vault".utf8).write(to: file)
        let before = try fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        XCTAssertTrue(ICloudFolderMigration.resolve(cloudDocs: root).didMigrate)
        XCTAssertTrue(ICloudFolderMigration.hasMovedMarker(in: old))
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("GIROCRAB_MOVED.txt"), encoding: .utf8), ICloudFolderMigration.movedMarkerText)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "vault")
        XCTAssertEqual(try fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, before)
        // the marker is not copied, and it is neither a vault file nor a legacy change
        XCTAssertFalse(ICloudFolderMigration.hasMovedMarker(in: new))
        XCTAssertFalse(ICloudFolderMigration.legacyChanged(cloudDocs: root, since: .distantPast, hashes: ICloudFolderMigration.vaultHashes(in: old)))
        // two sentences per language, old folder name never mentioned
        XCTAssertFalse(ICloudFolderMigration.movedMarkerText.localizedCaseInsensitiveContains("moneymoney"))
        XCTAssertTrue(ICloudFolderMigration.movedMarkerText.contains("„GiroCrab“") && ICloudFolderMigration.movedMarkerText.contains("“GiroCrab”"))
    }

    func test_no_marker_without_migration() throws {
        let root = try makeRoot()
        let old = root.appendingPathComponent("moneymoney"), new = root.appendingPathComponent("GiroCrab")
        try Data("v".utf8).write(to: old.appendingPathComponent(snapName))
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("f".utf8).write(to: new.appendingPathComponent("foreign.txt"))
        XCTAssertTrue(ICloudFolderMigration.resolve(cloudDocs: root).conflict)
        XCTAssertFalse(ICloudFolderMigration.hasMovedMarker(in: old))
    }

    func test_both_folders_with_vault_not_migrated_by_this_app_keeps_old() throws {
        let root = try makeRoot()
        let old = root.appendingPathComponent("moneymoney"), new = root.appendingPathComponent("GiroCrab")
        try Data("old".utf8).write(to: old.appendingPathComponent(snapName))
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: new.appendingPathComponent(snapName))
        let r = ICloudFolderMigration.resolve(cloudDocs: root)
        XCTAssertEqual(r.url, old)
        XCTAssertTrue(r.bothHaveVault)
        XCTAssertFalse(r.conflict)
        XCTAssertFalse(r.didMigrate)
        // nothing written anywhere
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: old.path), [snapName])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: new.path), [snapName])
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent(snapName), encoding: .utf8), "new")
    }

    func test_ios_hint_only_when_marker_present() throws {
        let root = try makeRoot()
        let old = root.appendingPathComponent("moneymoney")
        // a folder with the old name but no marker: no hint
        XCTAssertFalse(CloudSyncManager.folderWasMoved(old))
        try Data("x".utf8).write(to: old.appendingPathComponent("GIROCRAB_MOVED.txt"))
        XCTAssertTrue(CloudSyncManager.folderWasMoved(old))
        // a differently named folder with the marker also shows it
        let other = root.appendingPathComponent("Anderer")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertFalse(CloudSyncManager.folderWasMoved(other))
        try Data("x".utf8).write(to: other.appendingPathComponent("GIROCRAB_MOVED.txt"))
        XCTAssertTrue(CloudSyncManager.folderWasMoved(other))
    }

    func test_ios_new_vault_needs_confirmation_only_without_vault() throws {
        let root = try makeRoot()
        let dir = root.appendingPathComponent("moneymoney")
        XCTAssertTrue(ICloudFolderMigration.needsNewVaultConfirmation(dir))
        try Data("x".utf8).write(to: dir.appendingPathComponent("foreign.txt"))
        XCTAssertTrue(ICloudFolderMigration.needsNewVaultConfirmation(dir))
        try Data("v".utf8).write(to: dir.appendingPathComponent(snapName))
        XCTAssertFalse(ICloudFolderMigration.needsNewVaultConfirmation(dir))
    }

    func test_picked_parent_with_vault_subfolder_is_detected() throws {
        let root = try makeRoot()
        XCTAssertNil(ICloudFolderMigration.vaultSubfolder(in: root))
        let sub = root.appendingPathComponent("GiroCrab")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertNil(ICloudFolderMigration.vaultSubfolder(in: root))
        // only an undownloaded placeholder: still a vault
        try Data("p".utf8).write(to: sub.appendingPathComponent(".\(snapName).icloud"))
        XCTAssertEqual(ICloudFolderMigration.vaultSubfolder(in: root), "GiroCrab")
        XCTAssertFalse(ICloudFolderMigration.needsNewVaultConfirmation(sub))
    }

    func test_waitForVault_sees_file_that_appears_later() async throws {
        let root = try makeRoot()
        let dir = root.appendingPathComponent("moneymoney")
        let name = snapName
        Task.detached {
            try? await Task.sleep(for: .milliseconds(700))
            try? Data("v".utf8).write(to: dir.appendingPathComponent(name))
        }
        let found = await ICloudFolderMigration.waitForVault(in: dir, wait: 5)
        XCTAssertTrue(found)
        let empty = root.appendingPathComponent("leer")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        let notFound = await ICloudFolderMigration.waitForVault(in: empty, wait: 0.6)
        XCTAssertFalse(notFound)
    }
}
