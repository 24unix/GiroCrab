import CryptoKit
import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// Security lock × "Alle abrufen" (demo vault: every login asks for a TAN).
@MainActor
final class BankingPolicySyncTests: XCTestCase {
    private var model: AppModel!
    private let key = Curve25519.Signing.PrivateKey()
    private var fetcher: FakeFetcher!
    private var sequence: UInt64 = 0

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
        fetcher = FakeFetcher()
        model.bankingPolicy = BankingPolicy(
            publicKeys: [key.publicKey.rawRepresentation.base64EncodedString()],
            store: MemoryStore(),
            fetcher: fetcher,
            bundled: nil,
            distribution: .developerID,
            bundleVersion: "0.7.1"
        )
        try await publish(blocking: nil)
    }

    override func tearDown() async throws {
        model.cancelAllSync()
        model = nil
        clearBankingBlock()
    }

    /// Publishes a new policy: nil = no lock, [] = every connector, else these IDs.
    private func publish(blocking ids: [String]?) async throws {
        sequence += 1
        var rules = "[]"
        if let ids {
            let connectors = ids.isEmpty ? "" : #","connectors":[\#(ids.map { "\"\($0)\"" }.joined(separator: ","))]"#
            rules = #"[{"distribution":["developer-id"],"minimumVersion":"0.7.2"\#(connectors)}]"#
        }
        let json = Data(#"{"schema":1,"sequence":\#(sequence),"rules":\#(rules)}"#.utf8)
        fetcher.result = .success((json, try key.signature(for: json)))
        await model.bankingPolicy.refresh(force: true)
        XCTAssertTrue(model.bankingPolicy.verifiedOnline)
    }

    private var batch: [BankConnection] {
        model.connections.filter { !model.usesPortal($0) && !$0.allAccountsArchived }
    }

    private func waitUntil(_ what: String, timeout: Double = 5,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { XCTFail("Timed out waiting for \(what)", file: file, line: line); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForChallenge(of c: BankConnection, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil("TAN prompt of \(c.displayName)", file: file, line: line) {
            model.activeChallenge?.connection.id == c.id
        }
    }

    /// Logins whose connection key is unique in the batch (a lock on that key hits only them).
    private func uniquelyKeyed(_ logins: [BankConnection]) -> [Int] {
        let keys = logins.map(model.connectionKey)
        return logins.indices.filter { i in keys.filter { $0 == keys[i] }.count == 1 }
    }

    func testLockedLoginIsLeftOutAndNamedAtTheEnd() async throws {
        let logins = batch
        let candidates = uniquelyKeyed(logins).filter { $0 > 0 }
        try XCTSkipIf(logins.count < 3 || candidates.isEmpty, "demo vault needs three logins, one with its own key")
        let lockedIndex = candidates[0]
        let locked = logins[lockedIndex]
        try await publish(blocking: [model.connectionKey(locked)])
        XCTAssertNotNil(model.bankingGate(for: locked))

        model.requestSyncAll()
        let rest = logins.enumerated().filter { $0.offset != lockedIndex }.map(\.element)
        for (i, c) in rest.enumerated() {
            try await waitForChallenge(of: c)
            XCTAssertEqual(model.syncBatchProgress?.current, i + 1)
            XCTAssertEqual(model.syncBatchProgress?.total, rest.count)
            model.skipCurrentSync()
        }
        try await waitUntil("closing notice") { model.toast?.contains("Sicherheitssperre") == true }
        XCTAssertTrue(model.toast?.contains("\(locked.displayName) (Sicherheitssperre)") == true, model.toast ?? "")
        XCTAssertNil(model.syncBatchProgress)
        XCTAssertNil(model.errorMessage)
    }

    func testLockPublishedDuringTheBatchSkipsThatLogin() async throws {
        let logins = batch
        let candidates = uniquelyKeyed(logins).filter { $0 >= 1 && $0 < logins.count - 1 }
        try XCTSkipIf(logins.count < 3 || candidates.isEmpty, "demo vault needs a uniquely keyed login in the middle")
        let lockedIndex = candidates[0]
        let locked = logins[lockedIndex]

        model.requestSyncAll()
        for c in logins[..<lockedIndex] {
            try await waitForChallenge(of: c)
            if c.id == logins[lockedIndex - 1].id {
                // the lock arrives while the login before it waits for its TAN
                try await publish(blocking: [model.connectionKey(locked)])
            }
            model.skipCurrentSync()
        }

        let next = logins[lockedIndex + 1]
        try await waitForChallenge(of: next)
        XCTAssertEqual(model.syncBatchProgress?.total, logins.count)   // counted at the start
        XCTAssertNil(model.errorMessage)
        for c in logins[(lockedIndex + 1)...] {
            try await waitForChallenge(of: c)
            model.skipCurrentSync()
        }
        try await waitUntil("closing notice") { model.toast?.contains("Sicherheitssperre") == true }
        XCTAssertTrue(model.toast?.contains("\(locked.displayName) (Sicherheitssperre)") == true, model.toast ?? "")
        XCTAssertNil(model.syncBatchProgress)
        XCTAssertFalse(model.canSkipInSyncBatch)
    }

    func testFullLockDuringTheBatchEndsItWithAnError() async throws {
        let logins = batch
        try XCTSkipIf(logins.count < 3, "demo vault needs three logins")
        model.requestSyncAll()
        try await waitForChallenge(of: logins[0])
        try await publish(blocking: [])
        model.skipCurrentSync()

        try await waitUntil("lock error") { model.errorMessage != nil }
        XCTAssertEqual(model.errorTitle, String(localized: "Bankverbindungen gesperrt"))
        XCTAssertNil(model.syncBatchProgress)
        XCTAssertFalse(model.canSkipInSyncBatch)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(model.activeChallenge)
        XCTAssertNil(model.syncingConnectionID)
    }

    func testEverythingLockedShowsAnErrorAndStartsNothing() async throws {
        try await publish(blocking: [])
        XCTAssertTrue(model.bankingBlocksAll)
        model.requestSyncAll()
        try await waitUntil("lock error") { model.errorMessage != nil }
        XCTAssertEqual(model.errorTitle, String(localized: "Bankverbindungen gesperrt"))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(model.activeChallenge)
        XCTAssertNil(model.syncBatchProgress)
    }

    func testSingleSyncOfALockedLoginIsRefusedAndLeavesNoBatchBehind() async throws {
        let logins = batch
        try XCTSkipIf(logins.count < 2, "demo vault needs two logins")
        try await publish(blocking: [model.connectionKey(logins[0])])
        model.requestSync(logins[0])
        try await waitUntil("lock error") { model.errorMessage != nil }
        XCTAssertNil(model.syncBatchProgress)
        // an unlocked login still syncs normally afterwards
        model.errorMessage = nil
        if let other = logins.first(where: { model.bankingGate(for: $0) == nil }) {
            model.requestSync(other)
            try await waitForChallenge(of: other)
            XCTAssertNil(model.syncBatchProgress)
        }
    }

    /// The core enforces the same lock even if a UI path forgot to check.
    func testCoreRefusesALockedLoginDirectly() async throws {
        let logins = batch
        try XCTSkipIf(logins.isEmpty, "demo vault needs a login")
        try await publish(blocking: [model.connectionKey(logins[0])])
        XCTAssertTrue(isBankingBlocked(key: model.connectionKey(logins[0])))
        try await publish(blocking: nil)
        XCTAssertFalse(isBankingBlocked(key: model.connectionKey(logins[0])))
    }
}
