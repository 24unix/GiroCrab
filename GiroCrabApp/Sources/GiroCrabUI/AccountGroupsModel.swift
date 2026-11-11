import Foundation
import SwiftUI
import GiroCrabCore

extension UserGroup: @retroactive Identifiable {
    public var id: String { uuid }
}

extension Account {
    /// Archived ("aufgelöst"): kept with all bookings, no syncs or rule runs.
    var isArchived: Bool { archivedUnix != nil }
    var archivedDate: Date? { archivedUnix.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
}

/// How the accounts section of the sidebar is organised.
enum AccountSidebarMode: String, CaseIterable, Identifiable {
    case byGroup
    case byKind
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .byGroup: "Nach Gruppe"
        case .byKind: "Nach Kontoart"
        }
    }
    var symbol: String {
        switch self {
        case .byGroup: "folder"
        case .byKind: "square.stack.3d.up"
        }
    }
}

/// Group dialogs. One state for all of them, set from menus, ⇧⌘N, the
/// editor sheet and swipe actions, presented in one place.
enum GroupDialog {
    /// "Neue Gruppe …", optionally moving an account into the new group.
    case create(movingAccount: Int64? = nil)
    case rename(UserGroup)
    case delete(UserGroup)
    /// iOS swipe "Gruppe …".
    case moveAccount(Account)
    /// Renaming a group to the name of another one combines them.
    case merge(from: UserGroup, into: UserGroup)

    /// Text-input alert vs. confirmation dialog.
    var needsText: Bool {
        switch self {
        case .create, .rename: true
        case .delete, .moveAccount, .merge: false
        }
    }

    var title: Text {
        switch self {
        case .create: Text("Neue Gruppe")
        case .rename: Text("Gruppe umbenennen")
        case .delete(let g): Text("Gruppe „\(g.name)“ löschen?")
        case .moveAccount(let a): Text("„\(a.name)“ verschieben nach")
        case .merge(_, let into): Text("Mit „\(into.name)“ zusammenführen?")
        }
    }

    var isRename: Bool {
        if case .rename = self { return true }
        return false
    }

    /// Prefilled text of the input alert.
    var initialText: String {
        if case .rename(let g) = self { return g.name }
        return ""
    }
}

/// Symbols offered for groups (kept small on purpose).
enum GroupSymbols {
    static let named: [(symbol: String, name: LocalizedStringKey)] = [
        ("folder", "Ordner"), ("person", "Person"), ("person.2", "Paar"),
        ("figure.and.child.holdinghands", "Familie"), ("briefcase", "Beruf"), ("building.2", "Firma"),
        ("house", "Haus"), ("heart", "Herz"), ("graduationcap", "Ausbildung"),
        ("airplane", "Reisen"), ("chart.pie", "Vermögen"), ("banknote", "Geld"),
    ]
    static var all: [String] { named.map(\.symbol) }
}

extension AppModel {
    /// The view shown: the explicit choice, else "Nach Gruppe" once a group exists.
    var accountView: AccountSidebarMode {
        get { accountViewChoice ?? (hasUserGroups ? .byGroup : .byKind) }
        set { accountViewChoice = newValue }
    }

    var hasUserGroups: Bool { userGroups.contains { !$0.isUngrouped } }

    /// Real groups only (without "Ohne Gruppe"), for menus.
    var namedUserGroups: [UserGroup] { userGroups.filter { !$0.isUngrouped } }

    func userGroupAccountIDs(_ uuid: String) -> [Int64] {
        userGroups.first { $0.uuid == uuid }?.accounts.map(\.id) ?? []
    }

    func userGroup(of account: Account) -> UserGroup? {
        account.userGroupUuid.flatMap { u in userGroups.first { $0.uuid == u } }
    }

    /// Another group with this name (case-insensitive), if any.
    func userGroup(named name: String, except uuid: String) -> UserGroup? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        return namedUserGroups.first { $0.uuid != uuid && $0.name.lowercased() == key }
    }

    /// Renames a group. If another group already has that name, nothing is
    /// changed and the merge question is returned instead.
    func renameUserGroup(_ g: UserGroup, to name: String) -> GroupDialog? {
        if let other = userGroup(named: name, except: g.uuid) { return .merge(from: g, into: other) }
        updateUserGroup(g, name: name)
        return nil
    }

    /// Combines `from` into `into`: its accounts move over, `from` is removed.
    func mergeUserGroups(_ from: UserGroup, into: UserGroup) {
        guard let vault, !from.isUngrouped, !into.isUngrouped else { return }
        do {
            try vault.mergeUserGroups(fromUuid: from.uuid, intoUuid: into.uuid)
            if sidebarSelection == .userGroup(from.uuid) { sidebarSelection = .userGroup(into.uuid) }
            collapsedUserGroups.remove(from.uuid)
            afterGroupChange()
            toast = String(localized: "„\(from.name)“ mit „\(into.name)“ zusammengeführt")
        } catch {
            errorMessage = describe(error)
        }
    }

    private func afterGroupChange() {
        reloadAccounts()
        reloadHistory()
        reloadBookings()
    }

    /// Creates a group (and moves `accountID` into it). Returns the uuid.
    @discardableResult
    func createUserGroup(name: String, symbol: String = "folder", moving accountID: Int64? = nil) -> String? {
        guard let vault else { return nil }
        do {
            let uuid = try vault.createUserGroup(name: name, sfSymbol: symbol)
            if let accountID { try vault.moveAccountToGroup(accountId: accountID, groupUuid: uuid, index: nil) }
            accountView = .byGroup
            collapsedUserGroups.remove(uuid)
            afterGroupChange()
            return uuid
        } catch {
            errorMessage = describe(error)
            return nil
        }
    }

    func updateUserGroup(_ g: UserGroup, name: String? = nil, symbol: String? = nil, includeInTotal: Bool? = nil) {
        guard let vault, !g.isUngrouped else { return }
        do {
            try vault.updateUserGroup(
                uuid: g.uuid, name: name ?? g.name, sfSymbol: symbol ?? g.sfSymbol,
                includeInTotal: includeInTotal ?? g.includeInTotal)
            afterGroupChange()
        } catch {
            errorMessage = describe(error)
        }
    }

    func deleteUserGroup(_ g: UserGroup) {
        guard let vault, !g.isUngrouped else { return }
        do {
            try vault.deleteUserGroup(uuid: g.uuid)
            if sidebarSelection == .userGroup(g.uuid) { sidebarSelection = .allAccounts }
            collapsedUserGroups.remove(g.uuid)
            afterGroupChange()
            toast = String(localized: "Gruppe „\(g.name)“ gelöscht")
        } catch {
            errorMessage = describe(error)
        }
    }

    /// `uuid` nil or empty = "Ohne Gruppe"; `index` nil = at the end.
    func moveAccount(_ accountID: Int64, to uuid: String?, at index: Int? = nil) {
        guard let vault else { return }
        let target = (uuid?.isEmpty ?? true) ? nil : uuid
        do {
            try vault.moveAccountToGroup(accountId: accountID, groupUuid: target, index: index.map { UInt32(max(0, $0)) })
            afterGroupChange()
        } catch {
            errorMessage = describe(error)
        }
    }

    func reorderUserGroups(_ uuids: [String]) {
        guard let vault else { return }
        run2 { try vault.reorderUserGroups(uuids: uuids.filter { !$0.isEmpty }) }
        reloadAccounts()
    }

    func reorderAccounts(in uuid: String, ids: [Int64]) {
        guard let vault else { return }
        run2 { try vault.reorderAccountsInGroup(groupUuid: uuid.isEmpty ? nil : uuid, accountIds: ids) }
        reloadAccounts()
    }

    /// List `.onMove` for groups (indices into `namedUserGroups`).
    func moveUserGroups(from: IndexSet, to: Int) {
        var list = namedUserGroups.map(\.uuid)
        list.move(fromOffsets: from, toOffset: to)
        reorderUserGroups(list)
    }

    /// "Gruppen bearbeiten …": Settings › Kontogruppen.
    func openGroupSettings() {
        settingsTab = .groups
        #if os(macOS)
        groupSettingsRequested = true
        #else
        showSettings = true
        #endif
    }

    func toggleCollapsed(_ g: UserGroup) {
        if collapsedUserGroups.contains(g.uuid) { collapsedUserGroups.remove(g.uuid) } else { collapsedUserGroups.insert(g.uuid) }
    }

    private func run2(_ body: () throws -> Void) {
        do { try body() } catch { errorMessage = describe(error) }
    }
}
