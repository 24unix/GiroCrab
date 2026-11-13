import XCTest
@testable import GiroCrabUI

/// Debug builds and tests never touch the banking-policy keychain item: it
/// belongs to the signed release app, and reading it from an unsigned build
/// makes macOS ask for the login password on every launch of a new build.
@MainActor
final class BankingPolicyStoreTests: XCTestCase {
    func testTestsKeepThePolicyInMemory() {
        XCTAssertTrue(BankingPolicy.isRunningTests(ProcessInfo.processInfo.environment))
        let policy = BankingPolicy.makeDefault()
        XCTAssertTrue(policy.store is MemoryBankingPolicyStore, "never the keychain store")
        XCTAssertFalse(policy.store is KeychainBankingPolicyStore)
    }

    func testDebugBuildsUseTheirOwnFile() {
        let url = BankingPolicy.debugStoreURL
        XCTAssertEqual(url.lastPathComponent, "banking-policy-debug.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "GiroCrab")
    }

    func testFileStoreCreatesItsFolderAndRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gc-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileBankingPolicyStore(url: dir.appendingPathComponent("sub/banking-policy-debug.json"))
        XCTAssertNil(store.load())

        let policy = StoredBankingPolicy(json: Data("{\"sequence\":7}".utf8), signature: Data([1, 2, 3]), verifiedOnline: true)
        try store.save(policy)
        XCTAssertEqual(store.load(), policy)
    }
}
