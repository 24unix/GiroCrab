import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// "Alle abrufen": cancelling one login's prompt skips it instead of ending
/// the whole batch (demo vault: every login asks for a TAN).
@MainActor
final class SyncBatchTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
    }

    override func tearDown() async throws {
        model.cancelAllSync()
        model = nil
    }

    /// The logins "Alle abrufen" works through, in order.
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

    func testSkippingGoesOnWithTheNextLoginAndNamesTheSkippedOnes() async throws {
        let logins = batch
        try XCTSkipIf(logins.count < 3, "demo vault needs at least three logins")
        model.requestSyncAll()

        try await waitForChallenge(of: logins[0])
        XCTAssertEqual(model.syncBatchProgress?.current, 1)
        XCTAssertEqual(model.syncBatchProgress?.total, logins.count)
        XCTAssertTrue(model.canSkipInSyncBatch)
        model.skipCurrentSync()

        try await waitForChallenge(of: logins[1])
        XCTAssertEqual(model.syncBatchProgress?.current, 2)
        model.skipCurrentSync()

        for (i, c) in logins.enumerated().dropFirst(2) {
            try await waitForChallenge(of: c)
            XCTAssertEqual(model.syncBatchProgress?.current, i + 1)
            XCTAssertEqual(model.canSkipInSyncBatch, i < logins.count - 1)
            model.skipCurrentSync()   // on the last one: "Abbrechen" ends the batch
        }

        try await waitUntil("closing notice") { model.toast?.contains(logins[0].displayName) == true }
        for c in logins { XCTAssertTrue(model.toast?.contains(c.displayName) == true, c.displayName) }
        XCTAssertNil(model.syncBatchProgress)
        XCTAssertFalse(model.canSkipInSyncBatch)
        XCTAssertNil(model.syncingConnectionID)
    }

    func testCancelAllEndsTheBatch() async throws {
        let logins = batch
        try XCTSkipIf(logins.count < 2, "demo vault needs at least two logins")
        model.requestSyncAll()
        try await waitForChallenge(of: logins[0])

        model.cancelAllSync()
        XCTAssertNil(model.activeChallenge)
        XCTAssertNil(model.syncBatchProgress)
        XCTAssertFalse(model.canSkipInSyncBatch)

        // no further login is asked for
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(model.activeChallenge)
        XCTAssertNil(model.pendingLogin)
        XCTAssertNil(model.setupRequest)
    }

    /// "Weiter" and right after it "Überspringen": the bank's late answer for
    /// the skipped login must neither skip another login nor end the batch.
    func testLateAnswerOfASkippedLoginIsDropped() async throws {
        let logins = batch
        try XCTSkipIf(logins.count < 3, "demo vault needs at least three logins")
        let codeLogin = try XCTUnwrap(logins.dropLast().firstIndex { $0.connector == .tradeRepublic },
                                      "demo vault needs a code login that is not the last one")
        model.requestSyncAll()
        for c in logins[..<codeLogin] {
            try await waitForChallenge(of: c)
            model.skipCurrentSync()
        }
        try await waitForChallenge(of: logins[codeLogin])

        model.submitCode("1234")
        // let the code reach the bank, then skip while its answer is on the way
        try await waitUntil("code sent") { model.activeChallenge?.busy == true }
        await Task.yield()
        model.skipCurrentSync()

        let next = logins[codeLogin + 1]
        try await waitForChallenge(of: next)
        try await Task.sleep(for: .milliseconds(500))   // room for a late answer
        XCTAssertEqual(model.activeChallenge?.connection.id, next.id)
        XCTAssertEqual(model.syncBatchProgress?.current, codeLogin + 2)
        XCTAssertNil(model.errorMessage)
    }
}
