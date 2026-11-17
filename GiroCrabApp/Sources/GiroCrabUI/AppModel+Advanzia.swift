import Foundation
import GiroCrabCore

extension AppModel {
    func startAdvanzia(_ connection: BankConnection, password: String? = nil) {
        guard !isDemo, !Self.isMagicDemoLogin(connection.loginName), let pin = pinVault() else {
            if Self.isMagicDemoLogin(connection.loginName) { requestSync(connection) }
            return
        }
        if let running = advanziaWorkflow {
            if running.connection.id == connection.id && password == nil { running.showPrompt = true; return }
            running.cancel()
        }
        let flow = AdvanziaWorkflow(connection: connection, model: self, pin: pin, password: password)
        advanziaWorkflow = flow
        if !showAddBank { flow.start() }
    }

    /// Imports affect counters, the selected ledger and the dashboard. Keep the
    /// bulk queries off the main actor and bind every refresh to the imported vault.
    func advanziaDidImport(pin: VaultPin) async {
        await pin.checkpoint()
        guard isCurrent(pin), !Task.isCancelled else { return }
        do {
            let metadata = try await pin.run { v in
                let connections = try v.listBankConnections()
                let keys = try connections.map { ($0.id, try v.connectionKey(connectionId: $0.id)) }
                return (try v.listAccountGroups(), try v.listUserGroups(), connections, keys, try v.listTags())
            }
            guard isCurrent(pin), !Task.isCancelled else { return }
            endSelectionLoad()
            categoryRefreshTask?.cancel()
            applyAccountGroups(metadata.0, metadata.1)
            connections = metadata.2
            connectionKeys = Dictionary(uniqueKeysWithValues: metadata.3)
            tags = metadata.4
            refreshSelectedBookingHistory()
            refreshSidebarCounts()
            startSelectionLoad()
            loadDashboard()
        } catch {
            guard isCurrent(pin), !Task.isCancelled else { return }
            errorMessage = String(localized: "Daten gespeichert. Die Anzeige konnte nicht aktualisiert werden; bitte den Tresor erneut öffnen.")
        }
    }
}

extension AppModel {
    func advanziaSettingsDidSave(pin: VaultPin) async {
        await pin.checkpoint()
        do {
            let metadata = try await pin.run { v in
                (try v.listAccountGroups(), try v.listUserGroups(), try v.listBankConnections())
            }
            guard isCurrent(pin), !Task.isCancelled else { return }
            applyAccountGroups(metadata.0, metadata.1)
            connections = metadata.2
        } catch {
            guard isCurrent(pin) else { return }
            errorMessage = String(localized: "Daten gespeichert. Die Anzeige konnte nicht aktualisiert werden; bitte den Tresor erneut öffnen.")
        }
    }
}
