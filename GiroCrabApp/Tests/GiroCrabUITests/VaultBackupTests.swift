import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// Einstellungen › Sicherheit › „Tresor sichern …“ / „Tresor wiederherstellen …“.
@MainActor
final class VaultBackupTests: XCTestCase {
    private var model: AppModel!
    private let password = "Krabbe am Strand 7"

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--fresh-vault"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
        XCTAssertTrue(model.hasOwnVault)
        model.period = .all
    }

    override func tearDown() async throws { model = nil }

    private func temp(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        addTeardownBlock {
            for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + s) }
        }
        return url
    }

    /// A backup of a vault with demo accounts (another device), and its account count.
    private func demoBackup() throws -> (URL, UInt32) {
        let other = try Vault.open(path: temp("other").path, key: Data(repeating: 9, count: 32))
        _ = try other.seedDemoData()
        let url = temp("backup")
        try other.writeBackup(destPath: url.path, password: password)
        return (url, try other.accountCount())
    }

    func testRestoreShowsTheBackedUpAccounts() async throws {
        let (url, accounts) = try demoBackup()
        XCTAssertGreaterThan(accounts, 0)
        let ok = await model.restoreBackup(from: url, password: password)
        XCTAssertTrue(ok, model.toast ?? "")
        XCTAssertEqual(model.allAccounts.count, Int(accounts))
        XCTAssertFalse(model.bookings.isEmpty)
        XCTAssertFalse(model.demoActive)
    }

    func testWrongPasswordChangesNothing() async throws {
        let (url, _) = try demoBackup()
        let before = model.allAccounts.count
        let ok = await model.restoreBackup(from: url, password: "falsch")
        XCTAssertFalse(ok)
        XCTAssertNotNil(model.toast)
        XCTAssertEqual(model.allAccounts.count, before)
    }

    func testOwnBackupOpensOnAnotherDevice() async throws {
        let (url, _) = try demoBackup()
        _ = await model.restoreBackup(from: url, password: password)
        let data = await model.makeBackup(password: password)
        let file = temp("own")
        try XCTUnwrap(data).write(to: file)
        let other = try Vault.open(path: temp("device").path, key: Data(repeating: 4, count: 32))
        try other.restoreBackup(backupPath: file.path, password: password)
        XCTAssertEqual(Int(try other.accountCount()), model.allAccounts.count)
    }

    func testPasswordRules() {
        XCTAssertFalse(VaultBackup.acceptable("kurz", repeated: "kurz"))
        XCTAssertFalse(VaultBackup.acceptable("lang genug", repeated: "lang genug!"))
        XCTAssertTrue(VaultBackup.acceptable("lang genug", repeated: "lang genug"))
    }

    func testFileNameCarriesTheDate() {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 15; c.hour = 12
        let date = Calendar.current.date(from: c)!
        XCTAssertEqual(VaultBackup.fileName(date: date), "GiroCrab-Sicherung 2026-11-15.girocrab-backup")
    }
}
