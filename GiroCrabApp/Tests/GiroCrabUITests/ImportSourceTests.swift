import XCTest
@testable import GiroCrabUI

/// „Vorhandene Daten importieren“: which source is preselected.
final class ImportSourceTests: XCTestCase {
    /// A new device (empty vault): restoring a GiroCrab backup comes first.
    func testEmptyVaultStartsWithTheBackup() {
        XCTAssertEqual(MoneyMoneyImportSheet.defaultSource(vaultEmpty: true, mac: true), .backup)
        XCTAssertEqual(MoneyMoneyImportSheet.defaultSource(vaultEmpty: true, mac: false), .backup)
    }

    /// With accounts: adding data, as before (database on the Mac, export file on iOS).
    func testFilledVaultKeepsTheAddingSources() {
        XCTAssertEqual(MoneyMoneyImportSheet.defaultSource(vaultEmpty: false, mac: true), .database)
        XCTAssertEqual(MoneyMoneyImportSheet.defaultSource(vaultEmpty: false, mac: false), .export)
    }

    /// „Datenbank“ covers the backup and the other app's database.
    func testDatabaseGroupsBackupAndForeignDatabase() {
        XCTAssertTrue(MoneyMoneyImportSheet.Source.backup.isDatabase)
        XCTAssertTrue(MoneyMoneyImportSheet.Source.database.isDatabase)
        XCTAssertFalse(MoneyMoneyImportSheet.Source.export.isDatabase)
    }
}
