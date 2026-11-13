import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// Abrufprotokoll (#238): the model writes rows the log window reads.
@MainActor
final class SyncLogTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
    }

    override func tearDown() async throws { model = nil }

    private func rows(_ filter: SyncLogFilter = SyncLogFilter(connectionId: nil, onlyErrors: false, search: nil, limit: 0)) throws -> [SyncLogEntry] {
        try XCTUnwrap(model.vault).listSyncLog(filter: filter)
    }

    func testDemoVaultHasLogRowsWithErrors() throws {
        XCTAssertFalse(try rows().isEmpty)
        XCTAssertTrue(try rows().contains { $0.outcome == .error })
    }

    func testLogSyncWritesScrubbedRowAndBumpsVersion() throws {
        let conn = try XCTUnwrap(model.connections.first)
        let before = model.syncLogVersion
        model.logSync(connectionID: conn.id, source: .manual, outcome: .error,
                      message: "Anmeldung fehlgeschlagen, PIN=123456 für \(conn.loginName)")
        XCTAssertEqual(model.syncLogVersion, before + 1)
        let newest = try XCTUnwrap(rows().first)
        XCTAssertEqual(newest.outcome, .error)
        XCTAssertEqual(newest.connectionName, conn.displayName)
        XCTAssertFalse(newest.message.contains("123456"))
        XCTAssertFalse(newest.message.contains(conn.loginName))
    }

    func testOnlyErrorsFilter() throws {
        let errors = try rows(SyncLogFilter(connectionId: nil, onlyErrors: true, search: nil, limit: 0))
        XCTAssertFalse(errors.isEmpty)
        XCTAssertTrue(errors.allSatisfy { $0.outcome == .error })
    }

    func testCSVHasHeaderAndOneLinePerEntry() throws {
        let all = try rows()
        let csv = AppModel.syncLogCSV(all)
        XCTAssertEqual(csv.split(separator: "\n").count, all.count + 1)
        XCTAssertTrue(csv.hasPrefix("Zeit;Konto;"))
    }
}
