import Foundation
import CryptoKit
#if os(macOS)
import IOKit
#elseif os(iOS)
import UIKit
#endif

/// Names this installation's snapshot file in the sync folder
/// (`tresor-<id>.girocrab`). A random UUID kept in UserDefaults, never in
/// the vault, so two devices never share it after a sync. A hash of the
/// hardware id is stored next to it: a Mac set up with Migration Assistant
/// or from a backup carries the old UserDefaults along, and gets a new id.
enum SyncDeviceID {
    private static let idKey = "girocrab.sync.deviceID"
    private static let fingerprintKey = "girocrab.sync.deviceFingerprint"

    static func current(defaults: UserDefaults, hardwareID: String?) -> String {
        let fingerprint = hardwareID.map { id in
            SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        if let id = defaults.string(forKey: idKey),
           fingerprint == nil || fingerprint == defaults.string(forKey: fingerprintKey) {
            return id
        }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: idKey)
        if let fingerprint { defaults.set(fingerprint, forKey: fingerprintKey) }
        return id
    }

    /// `IOPlatformUUID` on macOS, the vendor id on iOS (changes when the app
    /// is reinstalled, which then simply starts a new snapshot file).
    @MainActor
    static func hardwareID() -> String? {
        #if os(macOS)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? String
        #elseif os(iOS)
        return UIDevice.current.identifierForVendor?.uuidString
        #else
        return nil
        #endif
    }
}
