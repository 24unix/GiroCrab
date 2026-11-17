import Foundation
import Security
import WebKit

/// Injectable Security calls: tests use an in-memory fake, never the user's keychain.
struct AdvanziaKeychainClient: @unchecked Sendable {
    var copy: ([String: Any]) -> (OSStatus, Data?)
    var add: ([String: Any]) -> OSStatus
    var update: ([String: Any], [String: Any]) -> OSStatus
    var delete: ([String: Any]) -> OSStatus
    static let system = Self(copy: { query in
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }, add: { SecItemAdd($0 as CFDictionary, nil) },
       update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
       delete: { SecItemDelete($0 as CFDictionary) })
}

enum AdvanziaLocalSecrets {
    static func key(_ profile: String, dataProtection: Bool = true) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.girocrab.advanzia.password.v1",
            kSecAttrAccount as String: profile, kSecAttrSynchronizable as String: false]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = dataProtection
        #endif
        return query
    }
    private static var stores: [Bool] {
        #if os(macOS)
        [true, false] // Same unsigned-build fallback as VaultKeyManager.
        #else
        [true]
        #endif
    }
    static func hasPassword(_ profile: String, using client: AdvanziaKeychainClient = .system) throws -> Bool {
        for store in stores {
            var q = key(profile, dataProtection: store)
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            let (status, _) = client.copy(q)
            if status == errSecSuccess { return true }
            if status != errSecItemNotFound && status != errSecMissingEntitlement { throw failure(status) }
        }
        return false
    }
    static func read(_ profile: String, using client: AdvanziaKeychainClient = .system) throws -> String? {
        for store in stores {
            var q = key(profile, dataProtection: store)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            let (status, data) = client.copy(q)
            if status == errSecSuccess {
                guard let data, let value = String(data: data, encoding: .utf8) else { throw failure(errSecDecode) }
                return value
            }
            if status != errSecItemNotFound && status != errSecMissingEntitlement { throw failure(status) }
        }
        return nil
    }
    static func save(password: String, for profile: String, using client: AdvanziaKeychainClient = .system) throws {
        guard UUID(uuidString: profile) != nil, !password.isEmpty else { throw failure(errSecParam) }
        let attrs: [String: Any] = [kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        for store in stores {
            let q = key(profile, dataProtection: store)
            let updated = client.update(q, attrs)
            let status = updated == errSecItemNotFound ? client.add(q.merging(attrs) { _, value in value }) : updated
            if status == errSecSuccess { return }
            if status != errSecMissingEntitlement { throw failure(status) }
        }
        throw failure(errSecMissingEntitlement)
    }
    static func delete(_ profile: String, using client: AdvanziaKeychainClient = .system) throws {
        for store in stores {
            let status = client.delete(key(profile, dataProtection: store))
            if ![errSecSuccess, errSecItemNotFound, errSecMissingEntitlement].contains(status) { throw failure(status) }
        }
    }
    private static func failure(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
}

@MainActor
enum AdvanziaLocalSession {
    static func dataStore(profile: String) -> WKWebsiteDataStore {
        guard let id = UUID(uuidString: profile) else { return .nonPersistent() }
        return WKWebsiteDataStore(forIdentifier: id)
    }
    static func clear(profile: String) async {
        let store = dataStore(profile: profile)
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        await store.removeData(ofTypes: types, for: records)
    }
}
