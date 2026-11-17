import XCTest
@testable import GiroCrabUI

#if os(macOS)
/// The MoneyMoney import panel opens in MoneyMoney's data folder, else in the home folder (#779).
final class MoneyMoneyLocationsTests: XCTestCase {
    private func makeHome(_ folders: [String]) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        for f in folders {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(f), withIntermediateDirectories: true)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    func testUsesMoneyMoneyFolderWhenPresent() throws {
        let home = try makeHome([MoneyMoneyLocations.relativeDataFolder])
        XCTAssertTrue(MoneyMoneyLocations.importDirectory(home: home).path
            .hasSuffix("com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney"))
    }

    func testFallsBackToHomeWhenMissing() throws {
        let home = try makeHome(["Library/Application Support"])
        XCTAssertEqual(MoneyMoneyLocations.importDirectory(home: home), home)
    }

    func testIgnoresFileAtThatPath() throws {
        let home = try makeHome([(MoneyMoneyLocations.relativeDataFolder as NSString).deletingLastPathComponent])
        FileManager.default.createFile(
            atPath: home.appendingPathComponent(MoneyMoneyLocations.relativeDataFolder).path, contents: Data())
        XCTAssertEqual(MoneyMoneyLocations.importDirectory(home: home), home)
    }
}
#endif
