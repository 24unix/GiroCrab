import SwiftUI
import GiroCrabCore

/// Column 1: collapsible account sections with subtotals, then categories.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    /// The one sidebar dialog on screen (group dialogs live in `model.groupDialog`).
    @State private var dialog: SidebarDialog?
    @State private var newCategoryName = ""
    @State private var budgetCategory: IDBox?
    /// Row a drag is hovering over (drop highlight).
    @State private var dropTarget: String?

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
            HStack(spacing: 8) {
                Image(systemName: "doc.on.doc").foregroundStyle(Theme.secondary).frame(width: 20)
                Text("Belege & PostBox").fontWeight(.medium)
                Spacer()
            }
            .tag(SidebarItem.documents)
            Button { model.openMoneyMoneyImport() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down.on.square").foregroundStyle(Theme.secondary).frame(width: 20)
                    Text("MoneyMoney-Import").fontWeight(.medium)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if !model.allAccounts.isEmpty {
                AccountsSectionHeader()
            }
            if model.accountView == .byGroup {
                userGroupRows
            } else {
                kindGroupRows
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
                        Divider()
                        Button("Bankzugang entfernen …", systemImage: "trash", role: .destructive) { dialog = .removeConnection(c.id) }
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
        #if os(macOS)
        // Keep traffic lights / sidebar toggle clear of the first row.
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 28) }
        #endif
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
        .confirmationDialog(
            dialog?.title ?? Text(verbatim: ""),
            isPresented: Binding(get: { dialog?.isConfirmation == true }, set: { if !$0, dialog?.isConfirmation == true { dialog = nil } }),
            titleVisibility: .visible,
            presenting: dialog
        ) { d in
            switch d {
            case .archiveAccount(let a): Button("Archivieren") { model.setAccountArchived(a, true) }
            case .deleteAccount(let a): Button("Endgültig löschen", role: .destructive) { model.deleteAccount(a.id) }
            case .removeConnection(let id): Button("Entfernen", role: .destructive) { model.removeConnection(id) }
            case .deleteCategory(let c): Button("„\(c.name)“ löschen", role: .destructive) { model.deleteCategory(c.id) }
            case .newCategory: EmptyView()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { d in
            switch d {
            case .archiveAccount(let a):
                Text("„\(a.name)“ wird nicht mehr abgerufen, von Regeln nicht mehr verändert und zählt nicht mehr zur Gesamtsumme. Buchungen, Kategorien, Belege und die Gruppe bleiben erhalten. Das Konto lässt sich jederzeit reaktivieren.")
            case .deleteAccount(let a):
                Text("„\(a.name)“ wird samt \(a.transactionCount) Buchungen, Belegen und Depotpositionen unwiderruflich gelöscht – auch aus Auswertungen und Kategoriesummen. Ist es das letzte Konto seines Bankzugangs, wird auch der Bankzugang mit den gespeicherten Zugangsdaten entfernt.")
            default: EmptyView()
            }
        }
        .alert(
            "Neue Kategorie",
            isPresented: Binding(get: { dialog?.isConfirmation == false }, set: { if !$0, dialog?.isConfirmation == false { dialog = nil } }),
            presenting: dialog
        ) { d in
            TextField("Name", text: $newCategoryName)
            Button("Anlegen") {
                if case .newCategory(let parent) = d {
                    let color = parent.flatMap { p in model.categories.first { $0.id == p }?.colorHex } ?? "#7A808A"
                    model.createCategory(name: newCategoryName, parent: parent, symbol: "tag.fill", color: color)
                }
                newCategoryName = ""
            }
            Button("Abbrechen", role: .cancel) { newCategoryName = "" }
        }
        .sheet(item: $budgetCategory) { box in BudgetEditorSheet(categoryID: box.id).environment(model) }
    }

    /// "Nach Kontoart": the fixed kind sections.
    @ViewBuilder
    private var kindGroupRows: some View {
        ForEach(model.groups) { group in
            let open = !model.collapsedGroups.contains(group.id)
            let toggle = {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if open { model.collapsedGroups.insert(group.id) } else { model.collapsedGroups.remove(group.id) }
                }
            }
            // Plain rows instead of List sections: macOS would otherwise
            // restore its own saved collapse state for sidebar sections.
            SectionHeader(group: group, open: open, toggle: toggle)
                .padding(.top, 10)
                .groupHeaderTap(SidebarItem.group(group.id), toggle: toggle)
                #if os(iOS)
                .contextMenu {
                    Button("Gruppenübersicht", systemImage: "list.bullet.rectangle") { model.sidebarSelection = .group(group.id) }
                }
                #endif
            ForEach(open ? group.accounts.filter(isShown) : []) { account in
                accountRow(account)
            }
        }
    }

    /// "Nach Gruppe": user groups, then "Ohne Gruppe".
    @ViewBuilder
    private var userGroupRows: some View {
        // a flattened tree: subgroups follow their group, indented by depth
        ForEach(model.userGroups.filter(model.isUserGroupVisible)) { group in
            let open = !model.collapsedUserGroups.contains(group.uuid)
            let toggle = { withAnimation(.easeInOut(duration: 0.15)) { model.toggleCollapsed(group) } }
            let indent = CGFloat(group.depth) * 14
            UserGroupHeader(group: group, open: open, toggle: toggle)
                .padding(.top, group.depth == 0 ? 10 : 4)
                .padding(.leading, indent)
                .groupHeaderTap(SidebarItem.userGroup(group.uuid), toggle: toggle)
                .contextMenu {
                    UserGroupMenu(group: group)
                }
                .modifier(DropHighlight(key: "g:" + group.uuid, target: $dropTarget))
                .draggable(GroupDrag.group(group.uuid)) {
                    Label(group.name, systemImage: group.sfSymbol).padding(6)
                }
                .dropDestination(for: String.self) { items, _ in
                    handleDrop(items, into: group, at: nil)
                } isTargeted: { dropTarget = $0 ? "g:" + group.uuid : (dropTarget == "g:" + group.uuid ? nil : dropTarget) }
            if open {
                if group.accounts.isEmpty && !group.isUngrouped && model.userGroupSubtree(group.uuid).count == 1 {
                    Text(emptyHint)
                        .font(.caption)
                        .foregroundStyle(Theme.tertiary)
                        .padding(.leading, 33 + indent)
                        .modifier(DropHighlight(key: "e:" + group.uuid, target: $dropTarget))
                        .dropDestination(for: String.self) { items, _ in
                            handleDrop(items, into: group, at: nil)
                        } isTargeted: { dropTarget = $0 ? "e:" + group.uuid : (dropTarget == "e:" + group.uuid ? nil : dropTarget) }
                }
                // offsets of the full list: a drop position counts hidden archived accounts too
                ForEach(Array(group.accounts.enumerated()).filter { isShown($0.element) }, id: \.element.id) { i, account in
                    accountRow(account)
                        .padding(.leading, indent)
                        .draggable(GroupDrag.account(account.id)) {
                            Label(account.name, systemImage: account.sfSymbol).padding(6)
                        }
                        .modifier(DropHighlight(key: "a:\(account.id)", target: $dropTarget))
                        .dropDestination(for: String.self) { items, _ in
                            handleDrop(items, into: group, at: i)
                        } isTargeted: { dropTarget = $0 ? "a:\(account.id)" : (dropTarget == "a:\(account.id)" ? nil : dropTarget) }
                }
            }
        }
    }

    private var emptyHint: LocalizedStringKey {
        #if os(macOS)
        "Konten hierher ziehen"
        #else
        "Keine Konten – Konto lange drücken, um es zuzuordnen"
        #endif
    }

    /// Account dropped on a row/header → move there; group dropped on a header → reorder.
    private func handleDrop(_ items: [String], into group: UserGroup, at index: Int?) -> Bool {
        var handled = false
        for item in items {
            if let id = GroupDrag.accountID(item) {
                model.moveAccount(id, to: group.uuid, at: index)
                handled = true
            } else if let uuid = GroupDrag.groupUUID(item), uuid != group.uuid, !uuid.isEmpty {
                var order = model.namedUserGroups.map(\.uuid).filter { $0 != uuid }
                let at = group.isUngrouped ? order.count : (order.firstIndex(of: group.uuid) ?? order.count)
                order.insert(uuid, at: at)
                model.reorderUserGroups(order)
                handled = true
            }
        }
        return handled
    }

    /// Archived accounts can be hidden (they stay in their group either way).
    private func isShown(_ account: Account) -> Bool {
        model.showArchivedAccounts || !account.isArchived
    }

    private func accountRow(_ account: Account) -> some View {
        AccountRow(account: account, syncing: model.syncingConnectionID != nil && model.syncingConnectionID == account.connectionId)
            .tag(SidebarItem.account(account.id))
            .contextMenu { accountMenu(account) }
            #if os(iOS)
            .swipeActions(edge: .trailing) {
                Button("Gruppe …", systemImage: "folder") { model.groupDialog = .moveAccount(account) }
                    .tint(Theme.accent)
            }
            #endif
    }

    @ViewBuilder
    private func accountMenu(_ account: Account) -> some View {
        AccountGroupMenu(account: account)
        AccountColorMenu(account: account)
        Divider()
        if !account.isArchived, let cid = account.connectionId, let conn = model.connections.first(where: { $0.id == cid }) {
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
        Divider()
        if account.isArchived {
            Button("Reaktivieren", systemImage: "arrow.uturn.backward") { model.setAccountArchived(account, false) }
            // only archived accounts can be deleted (GiroCrab/GiroCrab#43)
            Button("Konto löschen …", systemImage: "trash", role: .destructive) { dialog = .deleteAccount(account) }
        } else {
            Button("Konto archivieren …", systemImage: "archivebox") { dialog = .archiveAccount(account) }
        }
    }

    @ViewBuilder
    private func categoryMenu(_ category: GiroCrabCore.Category) -> some View {
        Button("Neue Unterkategorie …", systemImage: "plus") { dialog = .newCategory(parent: category.id) }
        Button("Monatsbudget festlegen …", systemImage: "gauge.with.dots.needle.67percent") { budgetCategory = IDBox(id: category.id) }
        Divider()
        Button("„\(category.name)“ löschen …", systemImage: "trash", role: .destructive) { dialog = .deleteCategory(category) }
    }
}

struct SectionHeader: View {
    let group: AccountGroup
    var open: Bool = true
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
            Text(group.name)
            Spacer()
            Text(Money.format(group.balanceCents))
                .monospacedDigit()
                .foregroundStyle(group.balanceCents < 0 && isLoanGroup ? Theme.loan : (group.balanceCents < 0 ? Theme.negative : Theme.secondary))
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Theme.secondary)
    }
}

extension SectionHeader {
    /// Loan groups are recognised by their accounts, not by the (translated) group name.
    var isLoanGroup: Bool { !group.accounts.isEmpty && group.accounts.allSatisfy { $0.kind == .loan } }
}

struct AccountRow: View {
    @Environment(AppModel.self) private var model
    let account: Account
    var syncing: Bool = false

    private var repaid: Double? {
        guard account.kind == .loan, let p = account.initialBalanceCents, p > 0 else { return nil }
        return max(0, min(1, 1 - Double(-account.balanceCents) / Double(p)))
    }

    var body: some View {
        HStack(spacing: 9) {
            AccountSignet(account: account, size: 24)
                // same colour as the account's marker in the booking list
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(model.accountColor(account.id))
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(Theme.canvas, lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(account.name).lineLimit(1)
                    if account.accessRevoked {
                        Image(systemName: "lock.slash")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("Zugriff entzogen: Die Bank liefert dieses Konto nicht mehr. Buchungen bleiben erhalten.")
                    }
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
                } else if let date = account.archivedDate {
                    Text("Archiviert \(date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year(.twoDigits)))")
                        .font(.caption2).foregroundStyle(Theme.secondary).lineLimit(1)
                        .help("Archiviert – wird nicht mehr abgerufen")
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
        .opacity(account.isArchived ? 0.55 : 1)
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

private extension View {
    /// macOS: clicking the header selects the group (the chevron collapses).
    /// iOS: the whole header collapses/expands – a bigger target than the
    /// chevron; the group overview is in the long-press menu.
    @ViewBuilder
    func groupHeaderTap(_ item: SidebarItem, toggle: @escaping () -> Void) -> some View {
        #if os(macOS)
        self.tag(item)
        #else
        self.contentShape(Rectangle()).onTapGesture(perform: toggle)
        #endif
    }
}

/// Accent outline on the row a drag is hovering over.
private struct DropHighlight: ViewModifier {
    let key: String
    @Binding var target: String?

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Theme.accent, lineWidth: 1.5)
                .opacity(target == key ? 1 : 0)
                .padding(-3)
        )
    }
}

/// Sidebar-only dialogs (account, bank login, category). One state instead
/// of one flag per dialog.
private enum SidebarDialog {
    case archiveAccount(Account)
    case deleteAccount(Account)
    case removeConnection(Int64)
    case deleteCategory(GiroCrabCore.Category)
    case newCategory(parent: Int64?)

    /// Confirmation dialog vs. text-input alert.
    var isConfirmation: Bool {
        if case .newCategory = self { return false }
        return true
    }

    var title: Text {
        switch self {
        case .archiveAccount: Text("Konto archivieren?")
        case .deleteAccount: Text("Archiviertes Konto endgültig löschen?")
        case .removeConnection: Text("Bankzugang entfernen?")
        case .deleteCategory: Text("Kategorie löschen?")
        case .newCategory: Text("Neue Kategorie")
        }
    }
}
