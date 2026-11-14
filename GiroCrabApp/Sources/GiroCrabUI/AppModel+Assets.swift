import SwiftUI
import GiroCrabCore

// Sachwerte / tangible assets (GitHub #87): AppModel side, see TangibleAssetsUI.swift.

extension AppModel {
    func reloadAssets() {
        guard let vault else { return }
        do {
            let ids = try vault.listTangibleAccountIds()
            assetStore.accountIDs = Set(ids)
            // one core pass for all accounts (prices and points are loaded once)
            var items = Dictionary(grouping: try vault.listAllAssetItems(), by: \.accountId)
            for id in ids where items[id] == nil { items[id] = [] }
            assetStore.items = items
        } catch {
            errorMessage = describe(error)
        }
        reloadSelectedAssetHistory()
    }

    /// Click on an item: its own value chart in the header; again = back to the account.
    func selectAssetItem(_ id: Int64?) {
        assetStore.selected = assetStore.selected == id ? nil : id
        reloadSelectedAssetHistory()
    }

    /// Back to the whole account (no-op without a selection).
    func deselectAssetItem() {
        guard assetStore.selected != nil else { return }
        assetStore.selected = nil
        reloadSelectedAssetHistory()
    }

    /// The selected item, if it belongs to `accountId`.
    func selectedAssetItem(in accountId: Int64) -> AssetItem? {
        assetStore.selected.flatMap(assetItem).flatMap { $0.accountId == accountId ? $0 : nil }
    }

    private func reloadSelectedAssetHistory() {
        guard let vault, let id = assetStore.selected, assetItem(id) != nil else {
            assetStore.selected = nil
            assetStore.selectedHistory = []
            return
        }
        do {
            assetStore.selectedHistory = try vault.assetItemHistory(itemId: id)
        } catch {
            errorMessage = describe(error)
        }
    }

    nonisolated static let runningUnitTests = NSClassFromString("XCTestCase") != nil

    func openAssetAction(_ kind: AssetActionRequest.Kind, itemId: Int64) {
        assetStore.action = AssetActionRequest(itemId: itemId, kind: kind)
    }

    func isTangible(_ accountId: Int64) -> Bool {
        assetStore.accountIDs.contains(accountId)
    }

    func assetItems(_ accountId: Int64) -> [AssetItem] {
        assetStore.items[accountId] ?? []
    }

    func assetItem(_ itemId: Int64) -> AssetItem? {
        assetStore.items.values.lazy.flatMap { $0 }.first { $0.id == itemId }
    }

    /// "Neues Sachwerte-Konto …": creates the account and selects it; its
    /// empty view offers "Sachwert hinzufügen …".
    func createTangibleAccount() {
        guard let vault else { return }
        do {
            let id = try vault.createTangibleAccount(name: "")
            reloadAccounts()
            sidebarSelection = .account(id)
        } catch {
            errorMessage = describe(error)
        }
    }

    func openAssetEditor(accountId: Int64, itemId: Int64? = nil) {
        assetStore.editor = AssetEditorRequest(accountId: accountId, itemId: itemId)
    }

    /// Runs a Sachwerte change and refreshes everything that shows its value.
    func changeAssets(_ body: (Vault) throws -> Void) throws {
        guard let vault else { throw CoreError.Database(message: "vault locked") }
        try body(vault)
        reloadAccounts(); reloadHistory()
    }

    /// Price (EUR per troy ounce) of `symbol` on `date` or the last day before;
    /// a primary-key lookup in the core, fine on the main actor.
    func assetPrice(symbol: String, on date: String) -> Int64? {
        ((try? vault?.assetPriceOn(symbol: symbol, date: date)) ?? nil)?.valueCents
    }

    /// Value of one piece of an item on `date` (gold: price × fine weight);
    /// the core loads only that item and one price.
    func assetUnitValue(itemId: Int64, on date: String) -> Int64? {
        (try? vault?.assetUnitValueOn(itemId: itemId, date: date)) ?? nil
    }

    /// Fetches missing gold prices (no request without automatic items).
    /// `userInitiated` shows the outcome; the automatic runs stay quiet.
    func refreshAssetPrices(userInitiated: Bool = false) {
        // the demo asks the API too (its gold items get real prices) – but not
        // under unit tests: they build demo models by the dozen and stay offline
        guard let vault, !assetStore.refreshing, !(isDemo && Self.runningUnitTests) else { return }
        assetStore.refreshing = true
        Task {
            defer { self.assetStore.refreshing = false }
            do {
                let r = try await vault.refreshAssetPrices(force: userInitiated)
                if r.requested { self.reloadAccounts(); self.reloadHistory() }
                guard userInitiated else { return }
                if let e = r.error {
                    self.toast = String(localized: "Kurse konnten nicht geladen werden: \(e)")
                } else if r.requested {
                    self.toast = String(localized: "Kurse aktualisiert")
                }
            } catch {
                if userInitiated { self.toast = describe(error) }
            }
        }
    }
}
