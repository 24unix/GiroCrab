import Foundation

/// „App zurücksetzen“ (GitHub #241): deletes the vault, its key, settings and
/// caches and starts over at the welcome screen (the demo vault).
extension AppModel {
    /// Asks the device owner, then deletes everything `VaultResources` lists.
    /// Failures are reported as a toast; a cancelled prompt does nothing.
    func resetApp(resources: VaultResources? = nil, authenticate: Bool = true) async {
        guard !isResettingApp else { return }
        isResettingApp = true
        defer { isResettingApp = false }
        if authenticate {
            do {
                try await VaultKeyManager.shared.authenticateOwner(
                    reason: String(localized: "GiroCrab zurücksetzen und alle Daten löschen"))
            } catch VaultKeyManager.KeyError.cancelled {
                return
            } catch {
                toast = error.localizedDescription
                return
            }
        }
        releaseVaultState()
        allAccountsCollapsed = false
        do {
            try AppReset.perform(resources ?? .current())
        } catch {
            toast = String(localized: "Zurücksetzen fehlgeschlagen: \(error.localizedDescription)")
            vaultState = Self.vaultMayHoldRealData ? .locked : .starting
            if vaultState == .starting { restartAfterReset() }
            return
        }
        demoDismissedLock = false
        lockPreview = false
        restartAfterReset()
        toast = String(localized: "GiroCrab wurde zurückgesetzt")
    }

    private func restartAfterReset() {
        vaultState = .starting
        bootstrapped = false
        bootstrap()
    }
}
