import Foundation
import GiroCrabCore

// MARK: Enable Banking key via iCloud Keychain

extension AppModel {
    nonisolated static let enableBankingKeySettings: Set<String> = ["enablebanking.application_id", "enablebanking.private_key_pem"]

    /// Only with the opt-in "Tresor-Schlüssel über iCloud-Schlüsselbund", and
    /// never for the demo vault.
    private var sharesEnableBankingKey: Bool {
        VaultKeyManager.shared.syncViaICloudKeychain && !demoActive && vault != nil
    }

    private func vaultEnableBankingApp() -> EnableBankingApp? {
        guard let vault else { return nil }
        let id = ((try? vault.getSetting(key: "enablebanking.application_id")) ?? nil) ?? ""
        let pem = ((try? vault.getSetting(key: "enablebanking.private_key_pem")) ?? nil) ?? ""
        return EnableBankingApp(applicationID: id, pem: pem)
    }

    /// After the own vault opened: take over an application another device
    /// shared, or share the one set up here.
    func reconcileEnableBankingKey() {
        guard sharesEnableBankingKey, let vault else {
            enableBankingKeyLog.info("open: not shared (opt-in \(VaultKeyManager.shared.syncViaICloudKeychain, privacy: .public), demo \(self.demoActive, privacy: .public))")
            return
        }
        let here = vaultEnableBankingApp()
        let action = EnableBankingKeySync.reconcile(vault: here, store: enableBankingKeyStore.load())
        enableBankingKeyLog.info("open: \(String(describing: action).prefix(8), privacy: .public)")
        switch action {
        case .none:
            break
        case .adopt(let app):
            do {
                try vault.setSetting(key: "enablebanking.application_id", value: app.applicationID)
                try vault.setSetting(key: "enablebanking.private_key_pem", value: app.pem)
                reloadSettings()
                if !UserDefaults.standard.bool(forKey: EnableBankingKeySync.noticeSuppressedKey) {
                    let banks = connections.filter { $0.connector == .enableBanking }.map(\.displayName)
                    enableBankingAdoptNotice = EnableBankingKeySync.notice(for: app, replaced: here?.isComplete == true, banks: banks)
                }
            } catch {
                Self.debugLog("enablebanking key adopt failed: \(error)")
            }
        case .upload(let app):
            uploadEnableBankingKey(app)
        }
    }

    /// After one of the two settings was saved here: share the new state (no
    /// reconcile – the store still holds the old key and must not win).
    func enableBankingSettingSaved(_ key: String) {
        guard Self.enableBankingKeySettings.contains(key), sharesEnableBankingKey,
              let app = vaultEnableBankingApp(), app.isComplete else { return }
        uploadEnableBankingKey(app)
    }

    private func uploadEnableBankingKey(_ app: EnableBankingApp) {
        do {
            try enableBankingKeyStore.save(app)
        } catch {
            // no iCloud Keychain here: the setting itself is stored anyway
            Self.debugLog("enablebanking key upload failed: \(error)")
        }
    }
}
