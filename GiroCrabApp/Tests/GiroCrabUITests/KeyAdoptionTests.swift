import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// After a pasted key opens the synced vault, the app leaves the demo and remembers real data (#308).
@MainActor
final class KeyAdoptionTests: XCTestCase {
    private let realDataKey = "girocrab.hasRealData"
    private var saved: Any?

    override func setUp() {
        saved = UserDefaults.standard.object(forKey: realDataKey)
        UserDefaults.standard.set(false, forKey: realDataKey)
    }

    override func tearDown() {
        if let saved { UserDefaults.standard.set(saved, forKey: realDataKey) } else { UserDefaults.standard.removeObject(forKey: realDataKey) }
    }

    func test_adoption_with_synced_data_leaves_demo_and_marks_real_data() throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertTrue(model.demoActive)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("adopt-\(UUID().uuidString).girocrab")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + s) } }
        let v = try Vault.open(path: url.path, key: Data(repeating: 7, count: 32))
        _ = try v.seedDemoData() // stands in for the merged snapshot: accounts exist
        model.finishKeyAdoption(vault: v)
        XCTAssertFalse(model.demoActive)
        XCTAssertEqual(model.vaultState, .open)
        XCTAssertEqual(UserDefaults.standard.object(forKey: realDataKey) as? Bool, true)
        model.stopAutoSync()
        CloudSyncManager.shared.stopAutoSync()
    }

    func test_adoption_without_data_stays_in_demo() throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("adopt-\(UUID().uuidString).girocrab")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + s) } }
        let v = try Vault.open(path: url.path, key: Data(repeating: 7, count: 32))
        model.finishKeyAdoption(vault: v)
        XCTAssertTrue(model.demoActive)
        XCTAssertEqual(UserDefaults.standard.object(forKey: realDataKey) as? Bool, false)
    }

    func test_adopt_without_own_vault_tells_the_user() {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        model.adoptSyncKey(String(repeating: "ab", count: 32))
        XCTAssertNotNil(model.toast)
    }
}
