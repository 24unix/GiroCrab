import XCTest
@testable import GiroCrabUI

/// „App zurücksetzen“ (#241): works on a temp vault and recorded callbacks, never the real one.
@MainActor
final class AppResetTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("reset-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func touch(_ name: String) -> URL {
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data([1]))
        return url
    }

    func testDeletesVaultSideFilesAndRunsStepsInOrder() throws {
        let vault = touch("tresor.girocrab")
        let wal = touch("tresor.girocrab-wal")
        let legacy = touch("tresor.key")
        var steps: [String] = []
        let resources = VaultResources(
            vaultURL: vault, extraPaths: [legacy],
            clearSettings: { steps.append("settings") },
            clearKeychainItems: { steps.append("keychain") },
            clearKey: { steps.append("key") })
        try AppReset.perform(resources)
        for url in [vault, wal, legacy] { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
        XCTAssertEqual(steps, ["settings", "keychain", "key"])
    }

    func testMissingFilesAreFine() throws {
        let resources = VaultResources(
            vaultURL: dir.appendingPathComponent("none.girocrab"),
            clearSettings: {}, clearKeychainItems: {}, clearKey: {})
        XCTAssertNoThrow(try AppReset.perform(resources))
    }

    func testFailedFileDeletionKeepsKeyAndSettings() throws {
        let vault = touch("tresor.girocrab")
        // A non-empty folder in the place of a side file cannot be removed by a read-only parent.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        var called = false
        let resources = VaultResources(
            vaultURL: vault,
            clearSettings: { called = true }, clearKeychainItems: { called = true }, clearKey: { called = true })
        XCTAssertThrowsError(try AppReset.perform(resources))
        XCTAssertFalse(called)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault.path))
    }

    func testResourcesNeverListTheBankingPolicy() {
        let r = VaultResources.current()
        XCTAssertFalse(r.filePaths.contains { $0.lastPathComponent.contains("banking-policy") })
    }

    func testResetAppRestartsAtDemo() async throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        let vault = touch("tresor.girocrab")
        var cleared = false
        let resources = VaultResources(
            vaultURL: vault, clearSettings: { cleared = true }, clearKeychainItems: {}, clearKey: {})
        await model.resetApp(resources: resources, authenticate: false)
        XCTAssertTrue(cleared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.path))
        XCTAssertFalse(model.isResettingApp)
        XCTAssertFalse(model.hasOwnVault)
    }
}
