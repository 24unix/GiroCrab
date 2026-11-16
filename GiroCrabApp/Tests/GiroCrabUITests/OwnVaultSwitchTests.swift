import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// #487: adding an account or importing data never writes into the demo vault,
/// also on a fresh install where no own vault exists yet.
@MainActor
final class OwnVaultSwitchTests: XCTestCase {
    private var model: AppModel!
    private var dir: URL!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertTrue(model.isDemo)
        XCTAssertFalse(model.hasOwnVault)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("own-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        model = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func newOwnVault() throws -> Vault {
        try Vault.open(path: dir.appendingPathComponent("own.girocrab").path, key: Data(repeating: 7, count: 32))
    }

    func testColdStartDefersActionUntilEmptyOwnVaultIsOpen() async throws {
        var unlockRequests = 0
        // like `unlock()`, which sets .unlocking first
        model.requestOwnVaultUnlock = { [model] in unlockRequests += 1; model!.vaultState = .unlocking }
        var ranInDemo = false
        var ranVault: Vault?
        model.runInOwnVault { [model] in
            ranInDemo = model!.isDemo
            ranVault = model!.vault
        }
        // Nothing ran yet; the user is sent to the unlock / key creation.
        XCTAssertEqual(unlockRequests, 1)
        XCTAssertNil(ranVault)
        XCTAssertEqual(model.vaultState, .unlocking)

        // Unlock finished with a brand-new, empty vault: it is kept (no demo fallback).
        let v = try newOwnVault()
        await model.adoptOpenedOwnVault(v, isEmpty: true)
        XCTAssertFalse(model.isDemo)
        XCTAssertTrue(model.vault === v)
        XCTAssertTrue(ranVault === v)
        XCTAssertFalse(ranInDemo)
        XCTAssertEqual(model.vaultState, .open)
        XCTAssertNil(model.pendingOwnVaultAction)
    }

    func testEmptyVaultWithoutRequestStillShowsDemo() async throws {
        let v = try newOwnVault()
        await model.adoptOpenedOwnVault(v, isEmpty: true)
        XCTAssertTrue(model.isDemo)
        XCTAssertTrue(model.hasOwnVault)
    }

    func testOpenOwnVaultIsSwitchedToBeforeAction() async throws {
        let v = try newOwnVault()
        await model.adoptOpenedOwnVault(v, isEmpty: true) // empty: demo shown, own vault open
        XCTAssertTrue(model.isDemo)
        var ranVault: Vault?
        model.runInOwnVault { [model] in ranVault = model!.vault }
        XCTAssertFalse(model.isDemo)
        XCTAssertTrue(ranVault === v)
    }

    func testExplicitDemoBankMayStayInDemoWithoutOwnVault() {
        var ran = false
        model.runInOwnVault(allowDemo: true) { ran = true }
        XCTAssertTrue(ran)
        XCTAssertTrue(model.isDemo)
    }
}
