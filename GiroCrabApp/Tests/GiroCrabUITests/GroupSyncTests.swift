import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// "Konten abrufen" in a group's menu: fetches the logins behind the group's
/// accounts (subgroups included) as one batch, like "Alle abrufen".
@MainActor
final class GroupSyncTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
    }

    override func tearDown() async throws {
        model.cancelAllSync()
        model = nil
    }

    /// Accounts of two different logins that "Alle abrufen" would fetch.
    private func twoAccountsOfDifferentLogins() throws -> (Account, Account) {
        let logins = model.connections.filter { !model.usesPortal($0) && !$0.allAccountsArchived }
        let accounts = logins.compactMap { c in
            model.allAccounts.first { $0.connectionId == c.id && !$0.isArchived }
        }
        try XCTSkipIf(accounts.count < 2, "demo vault needs accounts of two logins")
        return (accounts[0], accounts[1])
    }

    private func group(_ uuid: String?) throws -> UserGroup {
        try XCTUnwrap(model.userGroups.first { $0.uuid == uuid })
    }

    func testGroupFetchesTheLoginsOfItsAccountsAndSubgroups() throws {
        let (a, b) = try twoAccountsOfDifferentLogins()
        let top = model.createUserGroup(name: "Abruftest", moving: a.id)
        let sub = model.createUserGroup(name: "Unten", moving: b.id, parent: top)
        XCTAssertNotNil(sub)

        let ids = model.groupSyncConnections(try group(top)).map(\.id)
        XCTAssertEqual(Set(ids), [a.connectionId!, b.connectionId!])
        XCTAssertEqual(model.groupSyncConnections(try group(sub)).map(\.id), [b.connectionId!])
    }

    func testEachLoginIsFetchedOnceAndArchivedAccountsAreLeftOut() throws {
        let (a, _) = try twoAccountsOfDifferentLogins()
        let siblings = model.allAccounts.filter { $0.connectionId == a.connectionId && !$0.isArchived }
        let top = model.createUserGroup(name: "Abruftest", moving: a.id)
        for s in siblings where s.id != a.id { model.moveAccount(s.id, to: top) }
        XCTAssertEqual(model.groupSyncConnections(try group(top)).map(\.id), [a.connectionId!])

        // a group holding only archived accounts fetches nothing
        let archived = model.createUserGroup(name: "Archiv", moving: a.id)
        model.setAccountArchived(a, true)
        XCTAssertEqual(model.groupSyncConnections(try group(archived)), [])
    }

    func testGroupFetchRunsAsBatch() async throws {
        let (a, b) = try twoAccountsOfDifferentLogins()
        let top = model.createUserGroup(name: "Abruftest", moving: a.id)
        model.moveAccount(b.id, to: top)
        let logins = model.groupSyncConnections(try group(top))

        model.requestSyncGroup(try group(top))
        let end = Date().addingTimeInterval(5)
        while model.activeChallenge?.connection.id != logins[0].id {
            if Date() > end { return XCTFail("no TAN prompt for \(logins[0].displayName)") }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.syncBatchProgress?.total, 2)
        XCTAssertTrue(model.canSkipInSyncBatch)
    }
}
