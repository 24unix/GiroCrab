import Foundation
import os
import Security

/// What the key sharing did (never the key itself).
let enableBankingKeyLog = Logger(subsystem: "net.24unix.girocrab", category: "enablebanking-key")

/// An own Enable Banking application: its ID and private key (`.pem`).
struct EnableBankingApp: Equatable, Codable {
    var applicationID: String
    var pem: String

    /// Only with both set it can be used (or synced).
    var isComplete: Bool {
        !applicationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !pem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Same application and key, whatever whitespace the copies picked up.
    func sameAs(_ other: EnableBankingApp) -> Bool {
        applicationID.trimmingCharacters(in: .whitespacesAndNewlines) == other.applicationID.trimmingCharacters(in: .whitespacesAndNewlines)
            && pem.trimmingCharacters(in: .whitespacesAndNewlines) == other.pem.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Where the application is shared between devices.
protocol EnableBankingKeyStore {
    func load() -> EnableBankingApp?
    func save(_ app: EnableBankingApp) throws
}

/// The iCloud Keychain (synchronizable item, end-to-end encrypted by Apple).
/// Used only with the opt-in "Tresor-Schlüssel über iCloud-Schlüsselbund".
struct KeychainEnableBankingKeyStore: EnableBankingKeyStore {
    private let service = "de.girocrab.enablebanking"
    private let account = "application"

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: true,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func load() -> EnableBankingApp? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        enableBankingKeyLog.info("keychain load: status \(status, privacy: .public)")
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(EnableBankingApp.self, from: data)
    }

    func save(_ app: EnableBankingApp) throws {
        let data = try JSONEncoder().encode(app)
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(q as CFDictionary, nil)
        enableBankingKeyLog.info("keychain save: status \(status, privacy: .public)")
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

/// Shown after an application was taken over from another device (never the key).
struct EnableBankingAdoptNotice: Identifiable, Equatable {
    let id = UUID()
    var shortApplicationID: String
    var banks: [String]
    /// A different application was set up here before.
    var replaced: Bool

    var message: String {
        var lines = [replaced
            ? String(localized: "Ein anderes Gerät hat eine neue Enable-Banking-Anwendung gespeichert. Sie ersetzt die bisher hier eingerichtete.")
            : String(localized: "Die Enable-Banking-Anwendung eines anderen Geräts wurde aus dem iCloud-Schlüsselbund übernommen.")]
        lines.append(String(localized: "Anwendungs-ID: \(shortApplicationID)"))
        if !banks.isEmpty {
            lines.append(String(localized: "Verwendet von: \(banks.joined(separator: ", "))"))
        }
        return lines.joined(separator: "\n")
    }
}

enum EnableBankingKeySync {
    /// "Nicht mehr anzeigen" for `EnableBankingAdoptNotice`.
    static let noticeSuppressedKey = "girocrab.enableBankingAdoptNoticeSuppressed"

    static func notice(for app: EnableBankingApp, replaced: Bool, banks: [String]) -> EnableBankingAdoptNotice {
        let id = app.applicationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = id.count > 8 ? String(id.prefix(8)) + "…" : id
        return EnableBankingAdoptNotice(shortApplicationID: short, banks: banks, replaced: replaced)
    }

    enum Action: Equatable {
        case none
        /// Store → vault (another device saved it).
        case adopt(EnableBankingApp)
        /// Vault → store (set up here, not shared yet).
        case upload(EnableBankingApp)
    }

    /// What to do when a vault opens. A different application in the store
    /// wins: it is the one saved last on any device.
    static func reconcile(vault: EnableBankingApp?, store: EnableBankingApp?) -> Action {
        let v = vault.flatMap { $0.isComplete ? $0 : nil }
        let s = store.flatMap { $0.isComplete ? $0 : nil }
        switch (v, s) {
        case (nil, nil): return .none
        case (nil, let s?): return .adopt(s)
        case (let v?, nil): return .upload(v)
        case (let v?, let s?): return v.sameAs(s) ? .none : .adopt(s)
        }
    }
}
