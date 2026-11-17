import Foundation
import GiroCrabCore

extension AppModel {
    /// Preserve the normal banking-policy and own-vault flow. The pending unlock
    /// action never captures a password; the form owns and clears that value.
    func prepareAdvanziaAdd(login: String, completion: @escaping (VaultPin?) -> Void) {
        let magic = Self.isMagicDemoLogin(login.trimmingCharacters(in: .whitespacesAndNewlines))
        let prepare = { [self] in
            guard magic || bankingAllowsAdding(bankingGate(forNew: .advanzia)) else { completion(nil); return }
            runInOwnVault(allowDemo: magic) { [weak self] in completion(self?.pinVault()) }
        }
        if magic { prepare() } else { withFreshBankingPolicy(prepare) }
    }
}
