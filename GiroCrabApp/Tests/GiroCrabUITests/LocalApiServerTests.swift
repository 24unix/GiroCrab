import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// The socket of the external analysis (#136) runs only for the own unlocked
/// vault, only when enabled with a token, and goes away on lock, revoke and demo.
@MainActor
final class LocalApiServerTests: XCTestCase {
    private var model: AppModel!
    private var dir: URL!

    override func setUp() async throws {
        dir = URL(fileURLWithPath: "/tmp/gc-\(UUID().uuidString.prefix(8))")
        AppModel.localApiSocketPathOverride = dir.appendingPathComponent("s.sock").path
        model = AppModel(options: LaunchOptions(arguments: ["--fresh-vault"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
        XCTAssertTrue(model.holdsRealData)
        // The --fresh-vault file is wiped once per process: start every test from "off".
        await model.revokeLocalApiToken()
        await model.saveLocalApiScope(ShareScope(
            enabled: false, accountIds: [], shareAccountNumbers: false, shareCounterparty: true,
            sharePurpose: true, shareNotes: false, tokenSha256: ""))
        XCTAssertFalse(model.isLocalApiRunning)
    }

    override func tearDown() async throws {
        // Queued jobs may still start a server: let them finish first, while the
        // test path is set (a later one would bind the real socket path).
        for _ in 0..<3 {
            await Task.yield() // a job a didSet just spawned gets queued
            await model.localApiQueue?.value
        }
        model.stopLocalApiServer()
        model = nil
        AppModel.localApiSocketPathOverride = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private var socketExists: Bool {
        FileManager.default.fileExists(atPath: AppModel.localApiSocketPath)
    }

    private func awaitRunning(_ running: Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 {
            if model.isLocalApiRunning == running { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("server running = \(model.isLocalApiRunning), expected \(running)", file: file, line: line)
    }

    private func enable() async throws {
        let loaded = await model.loadLocalApiScope()
        var scope = try XCTUnwrap(loaded)
        scope.enabled = true
        await model.saveLocalApiScope(scope)
    }

    func testStartsOnlyWhenEnabledWithAToken() async throws {
        try await enable()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(model.isLocalApiRunning, "no token yet")
        let token = await model.createLocalApiToken()
        XCTAssertEqual(token?.hasPrefix("gcapi_"), true)
        try await awaitRunning(true)
        XCTAssertTrue(socketExists)

        await model.revokeLocalApiToken()
        try await awaitRunning(false)
        XCTAssertFalse(socketExists)
    }

    func testLockAndDemoStopTheSocket() async throws {
        try await enable()
        _ = await model.createLocalApiToken()
        try await awaitRunning(true)
        model.showDemo()
        try await awaitRunning(false)
        XCTAssertFalse(socketExists, "never served for the demo")
        model.showOwnVault()
        try await awaitRunning(true)
        model.lock()
        XCTAssertFalse(model.isLocalApiRunning)
        XCTAssertFalse(socketExists)
    }

    func testTurningOffStopsTheSocket() async throws {
        try await enable()
        _ = await model.createLocalApiToken()
        try await awaitRunning(true)
        let loaded = await model.loadLocalApiScope()
        var scope = try XCTUnwrap(loaded)
        scope.enabled = false
        await model.saveLocalApiScope(scope)
        try await awaitRunning(false)
    }

    func testAStartErrorIsKeptForTheStatus() async throws {
        // Longer than sun_path (104 bytes): bind fails.
        AppModel.localApiSocketPathOverride = dir.appendingPathComponent(String(repeating: "x", count: 120)).path
        try await enable()
        _ = await model.createLocalApiToken()
        for _ in 0..<300 where model.localApiStartError == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(model.localApiStartError)
        XCTAssertFalse(model.isLocalApiRunning)
        model.lock()
        XCTAssertNil(model.localApiStartError)
    }

    func testQuickSavesKeepTheNewest() async throws {
        let loaded = await model.loadLocalApiScope()
        var scope = try XCTUnwrap(loaded)
        scope.enabled = true
        var saves: [Task<Void, Never>] = []
        for ids in [[1], [1, 2], [1, 2, 3]] as [[Int64]] {
            scope.accountIds = ids
            let copy = scope
            saves.append(Task { await model.saveLocalApiScope(copy) })
        }
        for s in saves { await s.value }
        let stored = await model.loadLocalApiScope()
        XCTAssertEqual(stored?.accountIds, [1, 2, 3])
    }

    func testOnThenQuicklyOffLeavesTheSocketOff() async throws {
        _ = await model.createLocalApiToken()
        let loaded = await model.loadLocalApiScope()
        var scope = try XCTUnwrap(loaded)
        scope.enabled = true
        let on = scope
        scope.enabled = false
        let off = scope
        // Tasks made on the main actor start in order (async let would not).
        let first = Task { await model.saveLocalApiScope(on) }
        let second = Task { await model.saveLocalApiScope(off) }
        _ = await (first.value, second.value)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(model.isLocalApiRunning)
        XCTAssertFalse(socketExists)
    }

    func testQueuedSavesLandInTheOwnVaultAcrossTheDemo() async throws {
        let loaded = await model.loadLocalApiScope()
        var scope = try XCTUnwrap(loaded)
        scope.enabled = true
        scope.accountIds = [7]
        let save = Task { await model.saveLocalApiScope(scope) }
        await Task.yield() // queued while the own vault is shown
        model.showDemo()
        XCTAssertFalse(model.isLocalApiRunning)
        await save.value
        model.showOwnVault()
        let stored = await model.loadLocalApiScope()
        XCTAssertEqual(stored?.accountIds, [7])
    }

    func testAFailedStartIsRetried() async throws {
        let good = AppModel.localApiSocketPath
        AppModel.localApiSocketPathOverride = dir.appendingPathComponent(String(repeating: "x", count: 120)).path
        try await enable()
        _ = await model.createLocalApiToken()
        for _ in 0..<300 where model.localApiStartError == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(model.localApiStartError)
        AppModel.localApiSocketPathOverride = good // the obstacle is gone
        model.retryLocalApiStart()
        try await awaitRunning(true)
        XCTAssertNil(model.localApiStartError)
    }

    func testASaveThatCannotRunSaysSo() async throws {
        let loaded = await model.loadLocalApiScope()
        let scope = try XCTUnwrap(loaded)
        model.showDemo()
        let saved = await model.saveLocalApiScope(scope)
        XCTAssertFalse(saved)
        model.showOwnVault()
    }

    func testANormalUnlockStartsTheSocket() async throws {
        try await enable()
        _ = await model.createLocalApiToken()
        try await awaitRunning(true)
        let v = try XCTUnwrap(model.ownVault)
        model.lock()
        XCTAssertFalse(model.isLocalApiRunning)
        // The unlock path of the lock screen, with no settings call afterwards.
        model.vaultState = .unlocking
        let unlock = Task { await model.adoptOpenedOwnVault(v, isEmpty: false) }
        await Task.yield()
        XCTAssertNotEqual(model.vaultState, .open)
        XCTAssertFalse(model.isLocalApiRunning, "not behind the lock screen")
        await unlock.value
        XCTAssertEqual(model.vaultState, .open)
        try await awaitRunning(true)
    }

    func testANewKeyIsShownUntilItIsNoLongerValid() async throws {
        let first = await model.createLocalApiToken()
        XCTAssertNotNil(first)
        XCTAssertEqual(model.localApiNewToken, first)
        let second = await model.createLocalApiToken()
        XCTAssertEqual(model.localApiNewToken, second, "the newest one")
        await model.revokeLocalApiToken()
        XCTAssertNil(model.localApiNewToken, "revoked")
        _ = await model.createLocalApiToken()
        model.lock()
        XCTAssertNil(model.localApiNewToken, "never shown again after locking")
    }
}
