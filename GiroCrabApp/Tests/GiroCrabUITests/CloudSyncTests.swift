import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// iCloud sync with one snapshot file per device: device ids, the sync
/// folder's files, and the automatic-sync schedule.
final class CloudSyncTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "CloudSyncTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    // MARK: device id

    private static let uuidPattern = #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#

    func test_device_id_is_stable() {
        let a = SyncDeviceID.current(defaults: defaults, hardwareID: "A")
        let b = SyncDeviceID.current(defaults: defaults, hardwareID: "A")
        XCTAssertEqual(a, b)
        XCTAssertNotNil(a.range(of: Self.uuidPattern, options: .regularExpression))
    }

    func test_device_id_changes_with_hardware() {
        let a = SyncDeviceID.current(defaults: defaults, hardwareID: "A")
        let b = SyncDeviceID.current(defaults: defaults, hardwareID: "B")
        XCTAssertNotEqual(a, b)
    }

    func test_device_id_kept_without_hardware_id() {
        let a = SyncDeviceID.current(defaults: defaults, hardwareID: "A")
        let b = SyncDeviceID.current(defaults: defaults, hardwareID: nil)
        XCTAssertEqual(a, b)
    }

    // MARK: sync folder

    private static let key = Data(repeating: 7, count: 32)
    private var dirs: [URL] = []

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("gc-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    /// A device: its own local vault plus its view of the shared folder.
    private func device(_ folder: URL, key: Data = CloudSyncTests.key, seeded: Bool = false) throws -> (Vault, SyncFolder) {
        let local = try tempDir().appendingPathComponent("tresor.girocrab")
        let v = try Vault.open(path: local.path, key: key)
        if seeded { _ = try v.seedDemoData() }
        return (v, SyncFolder(dir: folder, deviceID: UUID().uuidString.lowercased()))
    }

    private func bookings(_ v: Vault) throws -> [Booking] {
        try v.listTransactions(filter: BookingFilter(
            accountIds: [], categoryId: nil, includeSubcategories: true, uncategorizedOnly: false,
            search: nil, dateFrom: nil, dateTo: nil, limit: 100_000, offset: 0,
            scope: .all, merchantKey: nil
        )).transactions
    }

    private func notes(_ v: Vault) throws -> Set<String> {
        Set(try bookings(v).map(\.note).filter { !$0.isEmpty })
    }

    /// A and B share the demo bookings, as after B's first sync.
    private func pair() throws -> (folder: URL, a: (Vault, SyncFolder), b: (Vault, SyncFolder)) {
        let folder = try tempDir()
        let a = try device(folder, seeded: true)
        let b = try device(folder)
        XCTAssertTrue(try a.1.write(vault: a.0).wrote)
        _ = b.1.merge(vault: b.0, peers: b.1.peers(), remoteKey: nil)
        XCTAssertGreaterThan(try bookings(b.0).count, 1)
        return (folder, a, b)
    }

    /// Notes a booking the other device doesn't touch: A the newest, B the oldest.
    private func note(_ v: Vault, newest: Bool, _ text: String) throws {
        let all = try bookings(v).sorted { $0.bookingDate < $1.bookingDate }
        let b = try XCTUnwrap(newest ? all.last : all.first)
        try v.updateTransactionNote(transactionId: b.id, note: text)
    }

    func test_two_devices_see_each_others_changes() throws {
        let (_, a, b) = try pair()
        try note(a.0, newest: true, "from A")
        XCTAssertTrue(try a.1.write(vault: a.0).wrote)
        _ = b.1.merge(vault: b.0, peers: b.1.peers(), remoteKey: nil)
        try note(b.0, newest: false, "from B")
        XCTAssertTrue(try b.1.write(vault: b.0).wrote)
        _ = a.1.merge(vault: a.0, peers: a.1.peers(), remoteKey: nil)
        XCTAssertEqual(try notes(a.0), ["from A", "from B"])
        XCTAssertEqual(try notes(b.0), ["from A", "from B"])
    }

    func test_overwrite_race_loses_nothing() throws {
        let (_, a, b) = try pair()
        try note(a.0, newest: true, "from A")
        try note(b.0, newest: false, "from B")
        // both write before either has seen the other's change
        XCTAssertTrue(try a.1.write(vault: a.0).wrote)
        XCTAssertTrue(try b.1.write(vault: b.0).wrote)
        _ = a.1.merge(vault: a.0, peers: a.1.peers(), remoteKey: nil)
        _ = b.1.merge(vault: b.0, peers: b.1.peers(), remoteKey: nil)
        XCTAssertEqual(try notes(a.0), ["from A", "from B"])
        XCTAssertEqual(try notes(b.0), ["from A", "from B"])
    }

    func test_legacy_file_is_read() throws {
        let folder = try tempDir()
        let (old, _) = try device(folder, seeded: true)
        try old.writeSnapshot(destPath: folder.appendingPathComponent(SyncFolder.legacyName).path)
        let (v, f) = try device(folder)
        XCTAssertEqual(f.peers().map(\.lastPathComponent), [SyncFolder.legacyName])
        let r = f.merge(vault: v, peers: f.peers(), remoteKey: nil)
        XCTAssertGreaterThan(r.stats.map(\.bookingsAdded).reduce(0, +), 0)
    }

    func test_conflict_copy_is_ignored() throws {
        let folder = try tempDir()
        let id = UUID().uuidString.lowercased()
        for name in ["tresor-\(id) 2.girocrab", "tresor-notauuid.girocrab", "tresor-\(id.uppercased()).girocrab"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data())
        }
        XCTAssertEqual(SyncFolder(dir: folder, deviceID: UUID().uuidString.lowercased()).peers(), [])
    }

    func test_own_file_is_not_a_peer() throws {
        let folder = try tempDir()
        let me = SyncFolder(dir: folder, deviceID: UUID().uuidString.lowercased())
        let other = "tresor-\(UUID().uuidString.lowercased()).girocrab"
        FileManager.default.createFile(atPath: me.ownURL.path, contents: Data())
        FileManager.default.createFile(atPath: folder.appendingPathComponent(other).path, contents: Data())
        XCTAssertEqual(me.peers().map(\.lastPathComponent), [other])
    }

    func test_foreign_key_peer_does_not_block_others() throws {
        let folder = try tempDir()
        let b = try device(folder, seeded: true)
        let c = try device(folder, key: Data(repeating: 9, count: 32), seeded: true)
        XCTAssertTrue(try b.1.write(vault: b.0).wrote)
        XCTAssertTrue(try c.1.write(vault: c.0).wrote)
        let (v, f) = try device(folder)
        let r = f.merge(vault: v, peers: f.peers(), remoteKey: nil)
        XCTAssertTrue(r.keyMismatch)
        XCTAssertGreaterThan(r.stats.map(\.bookingsAdded).reduce(0, +), 0)
        XCTAssertGreaterThan(try bookings(v).count, 0)
    }

    func test_unchanged_peer_is_skipped() throws {
        let (_, a, b) = try pair()
        let r = b.1.merge(vault: b.0, peers: b.1.peers(), remoteKey: nil)
        XCTAssertEqual(b.1.changedPeers(seen: r.seen), [])
        try note(a.0, newest: true, "from A")
        XCTAssertTrue(try a.1.write(vault: a.0).wrote)
        // A hasn't merged the transition file B could have changed, so it leaves it alone
        XCTAssertEqual(b.1.changedPeers(seen: r.seen).map(\.lastPathComponent), [a.1.ownURL.lastPathComponent])
    }

    private func legacyData(_ folder: URL) -> Data? {
        FileManager.default.contents(atPath: folder.appendingPathComponent(SyncFolder.legacyName).path)
    }

    func test_legacy_not_overwritten_after_key_mismatch() throws {
        let folder = try tempDir()
        let (old, _) = try device(folder, key: Data(repeating: 9, count: 32), seeded: true)
        try old.writeSnapshot(destPath: folder.appendingPathComponent(SyncFolder.legacyName).path)
        let before = legacyData(folder)
        let (v, f) = try device(folder, seeded: true)
        let r = f.merge(vault: v, peers: f.peers(), remoteKey: nil)
        XCTAssertTrue(r.keyMismatch)
        let w = try f.write(vault: v, merged: r.seen)
        XCTAssertTrue(w.wrote)
        XCTAssertNil(w.legacyModified)
        XCTAssertEqual(legacyData(folder), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.ownURL.path))
    }

    func test_legacy_written_once_merged() throws {
        let folder = try tempDir()
        let (old, _) = try device(folder, seeded: true)
        try old.writeSnapshot(destPath: folder.appendingPathComponent(SyncFolder.legacyName).path)
        let before = legacyData(folder)
        let (v, f) = try device(folder)
        let r = f.merge(vault: v, peers: f.peers(), remoteKey: nil)
        let w = try f.write(vault: v, merged: r.seen)
        XCTAssertNotNil(w.legacyModified)
        XCTAssertNotEqual(legacyData(folder), before)
        // our own write counts as merged: not picked up again as a change
        XCTAssertEqual(f.changedPeers(seen: r.seen.merging([SyncFolder.legacyName: w.legacyModified!]) { $1 }), [])
    }

    func test_legacy_not_overwritten_while_downloading() throws {
        let folder = try tempDir()
        FileManager.default.createFile(atPath: folder.appendingPathComponent(".\(SyncFolder.legacyName).icloud").path, contents: Data())
        let (v, f) = try device(folder, seeded: true)
        let w = try f.write(vault: v, merged: [:])
        XCTAssertTrue(w.wrote)
        XCTAssertNil(legacyData(folder))
    }

    func test_placeholder_peer_is_skipped_and_download_started() throws {
        let folder = try tempDir()
        let name = ".tresor-\(UUID().uuidString.lowercased()).girocrab.icloud"
        FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data())
        let start = Date()
        XCTAssertEqual(SyncFolder(dir: folder, deviceID: UUID().uuidString.lowercased()).peers(), [])
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func test_empty_vault_writes_nothing() throws {
        let folder = try tempDir()
        let (v, f) = try device(folder)
        XCTAssertFalse(try f.write(vault: v).wrote)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    // MARK: automatic sync schedule

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func test_write_after_change_settles() {
        var s = AutoSyncState()
        XCTAssertFalse(s.tick(changeCount: 10, now: t0).contains(.write))
        XCTAssertFalse(s.tick(changeCount: 11, now: t0 + 5).contains(.write))
        XCTAssertTrue(s.tick(changeCount: 11, now: t0 + 10).contains(.write))
        s.wrote(changeCount: 11)
        XCTAssertFalse(s.tick(changeCount: 11, now: t0 + 15).contains(.write))
    }

    func test_merge_does_not_schedule_a_write() {
        var s = AutoSyncState()
        _ = s.tick(changeCount: 10, now: t0)
        s.merged(changeCount: 25)
        XCTAssertFalse(s.tick(changeCount: 25, now: t0 + 5).contains(.write))
        XCTAssertFalse(s.tick(changeCount: 25, now: t0 + 10).contains(.write))
        XCTAssertFalse(s.hasPendingWrite)
    }

    func test_local_change_before_merge_is_still_written() {
        var s = AutoSyncState()
        _ = s.tick(changeCount: 10, now: t0)
        _ = s.tick(changeCount: 12, now: t0 + 5) // local edit, not settled yet
        s.merged(changeCount: 20)
        XCTAssertTrue(s.tick(changeCount: 20, now: t0 + 10).contains(.write))
    }

    func test_poll_every_30_seconds() {
        var s = AutoSyncState()
        let polls = stride(from: 0, through: 35, by: 5).filter {
            s.tick(changeCount: 10, now: t0 + TimeInterval($0)).contains(.poll)
        }
        XCTAssertEqual(polls, [0, 30])
    }

    func test_pending_write_reported() {
        var s = AutoSyncState()
        _ = s.tick(changeCount: 10, now: t0)
        XCTAssertFalse(s.hasPendingWrite)
        _ = s.tick(changeCount: 12, now: t0 + 5)
        XCTAssertTrue(s.hasPendingWrite)
    }

    // MARK: manager

    @MainActor
    func test_manager_sync_writes_own_and_legacy_file() async throws {
        let folder = try tempDir()
        let (v, _) = try device(folder, seeded: true)
        let sync = CloudSyncManager.shared
        sync.setFolderForTesting(folder)
        defer { sync.setFolderForTesting(nil) }
        await sync.sync(vault: v)
        XCTAssertNil(sync.lastError)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names.count, 2)
        XCTAssertTrue(names.contains(SyncFolder.legacyName))
        XCTAssertTrue(names.contains { $0.hasPrefix("tresor-") })
    }

    func test_contains_vault_detects_new_names() throws {
        let folder = try tempDir()
        XCTAssertFalse(SyncFolder.containsVault(folder))
        let copy = folder.appendingPathComponent("tresor-\(UUID().uuidString.lowercased()) 2.girocrab")
        FileManager.default.createFile(atPath: copy.path, contents: Data())
        XCTAssertFalse(SyncFolder.containsVault(folder))
        let placeholder = folder.appendingPathComponent(".tresor-\(UUID().uuidString.lowercased()).girocrab.icloud")
        FileManager.default.createFile(atPath: placeholder.path, contents: Data())
        XCTAssertTrue(SyncFolder.containsVault(folder))
        try FileManager.default.removeItem(at: placeholder)
        FileManager.default.createFile(atPath: folder.appendingPathComponent(SyncFolder.legacyName).path, contents: Data())
        XCTAssertTrue(SyncFolder.containsVault(folder))
    }
}
