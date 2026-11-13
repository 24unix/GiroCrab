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
    /// "Neue Gruppe …", optionally moving an account into the new group;
    /// with `parent`: "Neue Untergruppe …" of that group.
    case create(movingAccount: Int64? = nil, parent: UserGroup? = nil)
    case rename(UserGroup)
    /// "Umbenennen …" of an account (same alert as for groups).
    case renameAccount(Account)
    /// "Umbenennen …" of a category (same alert as for groups and accounts).
    case renameCategory(GiroCrabCore.Category)
    case delete(UserGroup)
    /// iOS swipe "Gruppe …".
    case moveAccount(Account)
    /// Renaming a group to the name of another one combines them.
    case merge(from: UserGroup, into: UserGroup)

    /// Text-input alert vs. confirmation dialog.
    var needsText: Bool {
        switch self {
        case .create, .rename, .renameAccount, .renameCategory: true
        case .delete, .moveAccount, .merge: false
        }
    }

    var title: Text {
        switch self {
        case .create(_, let parent?): Text("Neue Untergruppe in „\(parent.name)“")
        case .create: Text("Neue Gruppe")
        case .rename: Text("Gruppe umbenennen")
        case .renameAccount: Text("Konto umbenennen")
        case .renameCategory: Text("Kategorie umbenennen")
        case .delete(let g): Text("Gruppe „\(g.name)“ löschen?")
        case .moveAccount(let a): Text("„\(a.name)“ verschieben nach")
        case .merge(_, let into): Text("Mit „\(into.name)“ zusammenführen?")
        }
    }

    var isRename: Bool {
        switch self {
        case .rename, .renameAccount, .renameCategory: true
        default: false
        }
    }

    /// Prefilled text of the input alert.
    var initialText: String {
        switch self {
        case .rename(let g): g.name
        case .renameAccount(let a): a.name
        case .renameCategory(let c): c.name
        default: ""
        }
    }
}

/// One section of a group's "+" menu (#229): the accounts of another group,
/// or of "Ohne Gruppe" (`id` "").
struct AddableAccounts: Identifiable {
    let id: String
    let title: String
    let accounts: [Account]
}

/// What tells accounts of the same name apart (several "Girokonto"): the
/// IBAN, else the account number (depots), else the bank – marked when the
/// account is archived (closed), so it doesn't pass for an active one.
func accountDetail(_ a: Account) -> String {
    let id = accountIdentity(a)
    return a.isArchived ? String(localized: "Archiviert · \(id)") : id
}

/// IBAN, else account number, else bank.
func accountIdentity(_ a: Account) -> String {
    if !a.iban.isEmpty { return formatIBAN(a.iban) }
    if !a.accountNumber.isEmpty { return String(localized: "Konto \(a.accountNumber)") }
    return a.bankName
}

/// What the "Symbol & Farbe" popover edits.
enum IconColorTarget: Equatable {
    case account(Int64)
    case group(String)
    case category(Int64)
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

    /// The group and all its subgroups (the list is a flattened tree: a
    /// group's subgroups follow it with a greater depth).
    func userGroupSubtree(_ uuid: String) -> [UserGroup] {
        guard !uuid.isEmpty, let i = userGroups.firstIndex(where: { $0.uuid == uuid }) else {
            return userGroups.filter { $0.uuid == uuid }
        }
        let depth = userGroups[i].depth
        return [userGroups[i]] + userGroups[(i + 1)...].prefix { $0.depth > depth && !$0.isUngrouped }
    }

    /// Accounts of the group including its subgroups.
    func userGroupAccountIDs(_ uuid: String) -> [Int64] {
        userGroupSubtree(uuid).flatMap { $0.accounts.map(\.id) }
    }

    /// Accounts behind the group's sum, like the core's `balance_cents`: no
    /// archived accounts, no subgroups taken out of the total on their own (#208).
    func userGroupBalanceAccountIDs(_ uuid: String) -> [Int64] {
        var skipBelow: UInt32?
        var ids: [Int64] = []
        for (n, g) in userGroupSubtree(uuid).enumerated() {
            if let d = skipBelow {
                if g.depth > d { continue }
                skipBelow = nil
            }
            if n > 0 && !g.includeInTotal { skipBelow = g.depth; continue }
            ids += g.accounts.filter { !$0.isArchived }.map(\.id)
        }
        return ids
    }

    /// Groups `g` can be moved into: all but itself and its own subgroups.
    func parentCandidates(for g: UserGroup) -> [UserGroup] {
        let own = Set(userGroupSubtree(g.uuid).map(\.uuid))
        return namedUserGroups.filter { !own.contains($0.uuid) }
    }

    /// Shown in the sidebar: no group above it is collapsed.
    func isUserGroupVisible(_ g: UserGroup) -> Bool {
        var parent = g.parentUuid
        while let p = parent {
            if collapsedUserGroups.contains(p) { return false }
            parent = userGroups.first { $0.uuid == p }?.parentUuid
        }
        return true
    }

    /// Makes `g` a subgroup of `parent` (`nil` = top level).
    func setUserGroupParent(_ g: UserGroup, parent: String?) {
        guard let vault, !g.isUngrouped else { return }
        do {
            try vault.setUserGroupParent(uuid: g.uuid, parentUuid: parent)
            if let parent { collapsedUserGroups.remove(parent) }
            afterGroupChange()
        } catch {
            errorMessage = describe(error)
        }
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
    func createUserGroup(name: String, symbol: String = "folder", moving accountID: Int64? = nil, parent: String? = nil) -> String? {
        guard let vault else { return nil }
        do {
            let uuid = try vault.createUserGroup(name: name, sfSymbol: symbol)
            if let parent {
                try vault.setUserGroupParent(uuid: uuid, parentUuid: parent)
                collapsedUserGroups.remove(parent)
            }
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

    func setUserGroupColor(_ g: UserGroup, hex: String?) {
        guard let vault, !g.isUngrouped else { return }
        do {
            try vault.setUserGroupColor(uuid: g.uuid, colorHex: hex)
            afterGroupChange()
        } catch {
            errorMessage = describe(error)
        }
    }

    func renameAccount(_ accountId: Int64, to name: String) {
        guard let vault else { return }
        do {
            try vault.renameAccount(accountId: accountId, name: name)
            reloadAccounts()
        } catch {
            errorMessage = describe(error)
        }
    }

    /// Popover binding for one row: shown while `iconColorTarget` is it.
    func iconColorBinding(_ target: IconColorTarget) -> Binding<Bool> {
        Binding(
            get: { self.iconColorTarget == target },
            set: { if !$0, self.iconColorTarget == target { self.iconColorTarget = nil } }
        )
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

    /// "Ohne Gruppe" for the settings list (#229): always there, also when
    /// every account is in a group (the core then leaves it out).
    var ungroupedForSettings: UserGroup {
        userGroups.first(where: \.isUngrouped) ?? UserGroup(
            uuid: "", name: String(localized: "Ohne Gruppe"), sfSymbol: "tray", colorHex: "",
            sortOrder: .max, includeInTotal: true, inTotal: true, isUngrouped: true,
            parentUuid: nil, depth: 0, balanceCents: 0, accounts: []
        )
    }

    /// Accounts that can be added to group `uuid`: those without a group
    /// first, then the members of every other group in sidebar order.
    /// Archived (closed) accounts are left out – they stay where they are.
    func addableAccounts(for uuid: String) -> [AddableAccounts] {
        let others = userGroups.filter { $0.uuid != uuid }
        return (others.filter(\.isUngrouped) + others.filter { !$0.isUngrouped }).compactMap {
            let active = $0.accounts.filter { !$0.isArchived }
            guard !active.isEmpty else { return nil }
            return AddableAccounts(id: $0.uuid, title: $0.isUngrouped ? String(localized: "Ohne Gruppe") : $0.name, accounts: active)
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

    /// A group dropped onto a group row in the sidebar: into `target` (as its
    /// subgroup), or – `before` – right above it as its sibling; onto "Ohne
    /// Gruppe" it moves to the top level, at the end. Refuses moving a group
    /// into itself or its own subgroups. Returns whether anything happened.
    @discardableResult
    func dropUserGroup(_ uuid: String, onto target: UserGroup, before: Bool) -> Bool {
        guard !uuid.isEmpty, uuid != target.uuid,
              let moving = userGroups.first(where: { $0.uuid == uuid }),
              !userGroupSubtree(uuid).contains(where: { $0.uuid == target.uuid })
        else { return false }
        let parent: String? = target.isUngrouped ? nil : (before ? target.parentUuid : target.uuid)
        if moving.parentUuid != parent { setUserGroupParent(moving, parent: parent) }
        if target.isUngrouped || before {
            var order = namedUserGroups.map(\.uuid).filter { $0 != uuid }
            let at = target.isUngrouped ? order.count : (order.firstIndex(of: target.uuid) ?? order.count)
            order.insert(uuid, at: at)
            reorderUserGroups(order)
        }
        return true
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

    /// Whether the sidebar may show a drop mark for group `uuid` over `target`
    /// (see `dropUserGroup`): `into` = becomes its subgroup (lower half of the
    /// header or the group's accounts), else the line above its header. Never
    /// into itself or its own subgroups; "Ohne Gruppe" only takes groups above it.
    func canDropGroup(_ uuid: String, on target: UserGroup, into: Bool) -> Bool {
        guard !uuid.isEmpty, !userGroupSubtree(uuid).contains(where: { $0.uuid == target.uuid }) else { return false }
        return !(into && target.isUngrouped)
    }

    /// List `.onMove` for the accounts of group `uuid` (settings, #229).
    func moveAccounts(in uuid: String, from: IndexSet, to: Int) {
        guard let g = userGroups.first(where: { $0.uuid == uuid }) else { return }
        var ids = g.accounts.map(\.id)
        ids.move(fromOffsets: from, toOffset: to)
        reorderAccounts(in: uuid, ids: ids)
    }

    /// List `.onMove` for groups (indices into `namedUserGroups`).
    func moveUserGroups(from: IndexSet, to: Int) {
        var list = namedUserGroups.map(\.uuid)
        list.move(fromOffsets: from, toOffset: to)
        reorderUserGroups(list)
    }

    /// "Gruppen bearbeiten …": Settings › Kontogruppen.
    func openGroupSettings() { openSettings(.groups) }

    /// Opens Settings on the given tab (macOS: Settings window, iOS: sheet).
    func openSettings(_ tab: SettingsTab) {
        settingsTab = tab
        #if os(macOS)
        settingsRequested = true
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
