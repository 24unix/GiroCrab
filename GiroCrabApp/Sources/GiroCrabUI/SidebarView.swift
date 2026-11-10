import SwiftUI
import GiroCrabCore

/// Column 1: collapsible account sections with subtotals, then categories.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var newCategoryParent: Int64?? = nil
    @State private var newCategoryName = ""
    /// Parent of a group being created: `.some(nil)` = top level.
    @State private var newGroupParent: Int64?? = nil
    @State private var renamingGroup: AccountGroup?
    @State private var groupName = ""

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarSelection) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2").foregroundStyle(Theme.secondary).frame(width: 20)
                Text("Übersicht").fontWeight(.medium)
                Spacer()
                if model.newCount > 0 {
                    Text("\(model.newCount)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.selection))
                }
            }
            .tag(SidebarItem.allAccounts)
            .contextMenu {
                Button("Neue Kontogruppe …", systemImage: "folder.badge.plus") { newGroupParent = .some(nil) }
            }
            .dropDestination(for: String.self) { items, _ in drop(items, into: nil, before: nil) }
            HStack(spacing: 8) {
                Image(systemName: "doc.on.doc").foregroundStyle(Theme.secondary).frame(width: 20)
                Text("Belege & PostBox").fontWeight(.medium)
                Spacer()
            }
            .tag(SidebarItem.documents)
            Button { model.showMoneyMoneyImport = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down.on.square").foregroundStyle(Theme.secondary).frame(width: 20)
                    Text("MoneyMoney-Import").fontWeight(.medium)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            // Plain rows instead of List sections or OutlineGroup: macOS would
            // otherwise restore its own saved collapse state for sidebar sections.
            ForEach(visibleNodes) { node in
                switch node {
                case .group(let group):
                    SectionHeader(group: group, open: !model.isCollapsed(group), isLoanGroup: isLoanGroup(group)) {
                        withAnimation(.easeInOut(duration: 0.15)) { model.toggleCollapsed(group) }
                    }
                    .padding(.leading, indent(group.depth))
                    .padding(.top, group.depth == 0 ? 10 : 2)
                    .tag(SidebarItem.group(group.id))
                    .contextMenu { groupMenu(group) }
                    .draggable("group:\(group.id)")
                    .dropDestination(for: String.self) { items, _ in drop(items, into: group.id, before: nil) }
                case .account(let account, let depth):
                    AccountRow(account: account, syncing: model.syncingConnectionID != nil && model.syncingConnectionID == account.connectionId)
                        .padding(.leading, indent(depth))
                        .tag(SidebarItem.account(account.id))
                        .contextMenu { accountMenu(account) }
                        .draggable("account:\(account.id)")
                        .dropDestination(for: String.self) { items, _ in drop(items, into: account.groupId, before: node) }
                }
            }

            let pending = model.connections.filter { c in !model.allAccounts.contains { $0.connectionId == c.id } }
            if !pending.isEmpty {
                Text("Neue Bankzugänge")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondary)
                    .padding(.top, 10)
                ForEach(pending) { c in
                    HStack(spacing: 9) {
                        SymbolTile(symbol: c.sfSymbol, tint: c.connector.tint, size: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.displayName).lineLimit(1)
                            Text(model.missingSettings(for: c).isEmpty ? "Noch nicht abgerufen" : "Einrichtung fehlt")
                                .font(.caption2)
                                .foregroundStyle(model.missingSettings(for: c).isEmpty ? Theme.secondary : Theme.warning)
                        }
                        Spacer()
                        Button(model.missingSettings(for: c).isEmpty ? "Abrufen" : "Einrichten") { model.requestSync(c) }
                            .controlSize(.small)
                    }
                    .contextMenu {
                        Button("Bankzugang entfernen", systemImage: "trash", role: .destructive) { model.removeConnection(c.id) }
                    }
                }
            }

            Section {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.folder").foregroundStyle(Theme.warning).frame(width: 20)
                    Text("Ohne Kategorie")
                    Spacer()
                    if model.uncategorizedCount > 0 {
                        Text("\(model.uncategorizedCount)").font(.caption2.monospacedDigit()).foregroundStyle(Theme.secondary)
                    }
                }
                .tag(SidebarItem.uncategorized)
                ForEach(model.categoryTree) { root in
                    if let kids = root.children {
                        DisclosureGroup(isExpanded: Binding(
                            get: { model.expandedCategories.contains(root.id) },
                            set: { if $0 { model.expandedCategories.insert(root.id) } else { model.expandedCategories.remove(root.id) } }
                        )) {
                            ForEach(kids) { node in
                                CategoryRow(category: node.category)
                                    .tag(SidebarItem.category(node.id))
                                    .contextMenu { categoryMenu(node.category) }
                            }
                        } label: {
                            CategoryRow(category: root.category)
                                .contextMenu { categoryMenu(root.category) }
                        }
                        .tag(SidebarItem.category(root.id))
                    } else {
                        CategoryRow(category: root.category)
                            .tag(SidebarItem.category(root.id))
                    }
                }
            } header: {
                Text("Kategorien").font(.caption.weight(.semibold))
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebar)
        .navigationTitle("GiroCrab")
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                if model.isDemo {
                    Image(systemName: "theatermasks")
                    Text("Demo-Daten – keine echte Bank verbunden")
                    Button(model.hasOwnVault ? "Eigener Tresor" : "Tresor öffnen") { model.showOwnVault() }
                        .buttonStyle(.borderless)
                } else {
                    Image(systemName: "lock.fill")
                    Text("Verschlüsselt · \(model.lastSyncText)")
                    Button("Demo") { model.showDemo() }
                        .buttonStyle(.borderless)
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(.bar)
        }
        .alert("Neue Kontogruppe", isPresented: Binding(get: { newGroupParent != nil }, set: { if !$0 { newGroupParent = nil } })) {
            TextField("Name", text: $groupName)
            Button("Anlegen") {
                model.createAccountGroup(name: groupName, parent: newGroupParent ?? nil)
                groupName = ""
                newGroupParent = nil
            }
            Button("Abbrechen", role: .cancel) { groupName = ""; newGroupParent = nil }
        }
        .alert("Gruppe umbenennen", isPresented: Binding(get: { renamingGroup != nil }, set: { if !$0 { renamingGroup = nil } })) {
            TextField("Name", text: $groupName)
            Button("Umbenennen") {
                if let g = renamingGroup { model.renameAccountGroup(g.id, name: groupName) }
                groupName = ""
                renamingGroup = nil
            }
            Button("Abbrechen", role: .cancel) { groupName = ""; renamingGroup = nil }
        }
        .alert("Neue Kategorie", isPresented: Binding(get: { newCategoryParent != nil }, set: { if !$0 { newCategoryParent = nil } })) {
            TextField("Name", text: $newCategoryName)
            Button("Anlegen") {
                let parent = newCategoryParent ?? nil
                let color = parent.flatMap { p in model.categories.first { $0.id == p }?.colorHex } ?? "#7A808A"
                model.createCategory(name: newCategoryName, parent: parent, symbol: "tag.fill", color: color)
                newCategoryName = ""
                newCategoryParent = nil
            }
            Button("Abbrechen", role: .cancel) { newCategoryParent = nil }
        }
    }

    // MARK: - Account tree

    /// Sidebar nodes without the contents of collapsed groups.
    private var visibleNodes: [SidebarNode] {
        var out: [SidebarNode] = []
        var hiddenBelow: UInt32?
        for node in model.sidebar {
            let depth: UInt32
            switch node {
            case .group(let g): depth = g.depth
            case .account(_, let d): depth = d
            }
            if let h = hiddenBelow, depth > h { continue }
            hiddenBelow = nil
            out.append(node)
            if case .group(let g) = node, model.isCollapsed(g) { hiddenBelow = depth }
        }
        return out
    }

    private func indent(_ depth: UInt32) -> CGFloat { CGFloat(depth) * 14 }

    /// Loan groups are recognised by their accounts, not by the (translated) group name.
    private func isLoanGroup(_ group: AccountGroup) -> Bool {
        let accounts = model.allAccounts.filter { group.accountIds.contains($0.id) }
        return !accounts.isEmpty && accounts.allSatisfy { $0.kind == .loan }
    }

    /// "A › B" for the move menu.
    private func path(_ group: AccountGroup) -> String {
        var names = [group.name]
        var parent = group.parentId
        while let p = parent, let g = model.accountGroups.first(where: { $0.id == p }), names.count < 32 {
            names.insert(g.name, at: 0)
            parent = g.parentId
        }
        return names.joined(separator: " › ")
    }

    /// `group` and every group below it.
    private func subtree(_ group: AccountGroup) -> Set<Int64> {
        var ids: Set<Int64> = [group.id]
        var inside = false
        for node in model.sidebar {
            guard case .group(let g) = node else { continue }
            if g.id == group.id { inside = true; continue }
            if inside {
                if g.depth <= group.depth { break }
                ids.insert(g.id)
            }
        }
        return ids
    }

    private func parentOf(_ node: SidebarNode) -> Int64? {
        switch node {
        case .group(let g): g.parentId
        case .account(let a, _): a.groupId
        }
    }

    /// Handles a dropped "account:<id>" / "group:<id>": into `parent`, before
    /// `before` (a sibling) or at the end.
    private func drop(_ items: [String], into parent: Int64?, before: SidebarNode?) -> Bool {
        guard let item = items.first else { return false }
        let parts = item.split(separator: ":")
        guard parts.count == 2, let id = Int64(parts[1]) else { return false }
        let dragged = parts[0] == "group" ? "g\(id)" : "a\(id)"
        var index = UInt32.max
        if let before {
            // Position among the siblings, without the dragged item and the Closed group.
            let siblings = model.sidebar.filter { n in
                if case .group(let g) = n, g.isClosedGroup { return false }
                return parentOf(n) == parent && n.id != dragged
            }
            if let i = siblings.firstIndex(where: { $0.id == before.id }) { index = UInt32(i) }
        }
        switch parts[0] {
        case "account": model.moveAccount(id, to: parent, index: index)
        case "group" where id != parent: model.moveAccountGroup(id, to: parent, index: index)
        default: return false
        }
        return true
    }

    @ViewBuilder
    private func groupMenu(_ group: AccountGroup) -> some View {
        if !group.isClosedGroup {
            Button("Neue Kontogruppe …", systemImage: "folder.badge.plus") { newGroupParent = .some(group.id) }
        }
        Button("Umbenennen …", systemImage: "pencil") {
            groupName = group.name
            renamingGroup = group
        }
        if !group.isClosedGroup {
            let excluded = subtree(group)
            Menu("Verschieben nach") {
                Button("Oberste Ebene") { model.moveAccountGroup(group.id, to: nil) }
                ForEach(model.accountGroups.filter { !excluded.contains($0.id) }) { target in
                    Button(path(target)) { model.moveAccountGroup(group.id, to: target.id) }
                }
            }
            Divider()
            Button("Gruppe löschen", systemImage: "trash", role: .destructive) { model.deleteAccountGroup(group.id) }
        }
    }

    @ViewBuilder
    private func accountMenu(_ account: Account) -> some View {
        if let cid = account.connectionId, let conn = model.connections.first(where: { $0.id == cid }) {
            Button("\(conn.displayName) abrufen", systemImage: "arrow.triangle.2.circlepath") { model.requestSync(conn) }
        }
        if !account.iban.isEmpty {
            Button("IBAN kopieren", systemImage: "doc.on.doc") {
                #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(account.iban, forType: .string)
                #else
                UIPasteboard.general.string = account.iban
                #endif
            }
        }
        Menu("Verschieben nach") {
            Button("Oberste Ebene") { model.moveAccount(account.id, to: nil) }
            ForEach(model.accountGroups) { target in
                Button(path(target)) { model.moveAccount(account.id, to: target.id) }
            }
        }
        if account.closed {
            Button("Konto wieder öffnen", systemImage: "tray.and.arrow.up") { model.reopenAccount(account.id) }
        } else {
            Button("Konto schließen", systemImage: "archivebox") { model.closeAccount(account.id) }
        }
    }

    @ViewBuilder
    private func categoryMenu(_ category: GiroCrabCore.Category) -> some View {
        Button("Neue Unterkategorie …", systemImage: "plus") { newCategoryParent = .some(category.id) }
        Button("„\(category.name)“ löschen", systemImage: "trash", role: .destructive) { model.deleteCategory(category.id) }
    }
}

struct SectionHeader: View {
    let group: AccountGroup
    var open: Bool = true
    var isLoanGroup = false
    var toggle: () -> Void = {}

    var body: some View {
        HStack(spacing: 5) {
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 12, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.tertiary)
            Image(systemName: group.sfSymbol)
                .font(.system(size: 10))
                .frame(width: 14)
            Text(group.name).lineLimit(1)
            Spacer()
            Text(Money.format(group.balanceCents))
                .monospacedDigit()
                .foregroundStyle(group.balanceCents < 0 && isLoanGroup ? Theme.loan : (group.balanceCents < 0 ? Theme.negative : Theme.secondary))
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Theme.secondary)
    }
}

struct AccountRow: View {
    let account: Account
    var syncing: Bool = false

    private var repaid: Double? {
        guard account.kind == .loan, let p = account.initialBalanceCents, p > 0 else { return nil }
        return max(0, min(1, 1 - Double(-account.balanceCents) / Double(p)))
    }

    var body: some View {
        HStack(spacing: 9) {
            AccountSignet(account: account, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(account.name).lineLimit(1)
                    if account.newCount > 0 {
                        Circle().fill(Theme.accent).frame(width: 6, height: 6)
                    }
                }
                if let repaid {
                    ProgressView(value: repaid)
                        .progressViewStyle(.linear)
                        .tint(Theme.loan.opacity(0.7))
                        .controlSize(.mini)
                        .frame(maxWidth: 110)
                        .help("\(repaid.formatted(.percent.precision(.fractionLength(0)))) getilgt")
                } else {
                    Text(account.bankName).font(.caption2).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if syncing {
                ProgressView().controlSize(.mini)
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text(Money.format(account.balanceCents, currency: account.currency))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(account.kind == .loan ? Theme.loan : (account.balanceCents < 0 ? Theme.negative : Theme.text))
                if let repaid {
                    Text("\(repaid.formatted(.percent.precision(.fractionLength(0)))) getilgt").font(.caption2).foregroundStyle(Theme.tertiary)
                }
            }
        }
        .padding(.vertical, 1)
    }
}

struct CategoryRow: View {
    let category: GiroCrabCore.Category

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: category.sfSymbol)
                .foregroundStyle(Color.readable(hex: category.colorHex).opacity(0.85))
                .frame(width: 20)
            Text(category.name).lineLimit(1)
            Spacer(minLength: 4)
            if category.totalCents != 0 {
                Text(Money.format(category.totalCents))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondary)
            }
        }
    }
}
