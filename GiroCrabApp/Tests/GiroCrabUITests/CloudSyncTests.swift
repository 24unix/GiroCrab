import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// iCloud sync with one snapshot file per device: device ids, the sync
/// folder's files, and the automatic-sync schedule.
final class CloudSyncTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "CloudSyncTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    // MARK: device id

    private static let uuidPattern = #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#

    func test_device_id_is_stable() {
        let a = SyncDeviceID.current(defaults: defaults, hardwareID: "A")
        let b = SyncDeviceID.current(defaults: defaults, hardwareID: "A")
        XCTAssertEqual(a, b)
        XCTAssertNotNil(a.range(of: Self.uuidPattern, options: .regularExpression))
    }

    func test_device_id_changes_with_hardware() {
        let a = SyncDeviceID.current(defaults: defaults, hardwareID: "A")
        let b = SyncDeviceID.current(defaults: defaults, hardwareID: "B")
        XCTAssertNotEqual(a, b)
    }

    func test_device_id_kept_without_hardware_id() {
        let a = SyncDeviceID.current(defaults: defaults, hardwareID: "A")
        let b = SyncDeviceID.current(defaults: defaults, hardwareID: nil)
        XCTAssertEqual(a, b)
    }
}
