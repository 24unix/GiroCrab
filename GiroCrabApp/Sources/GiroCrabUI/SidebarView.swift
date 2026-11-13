import SwiftUI
import GiroCrabCore

/// Column 1: collapsible account sections with subtotals, then categories.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    /// The one sidebar dialog on screen (group dialogs live in `model.groupDialog`).
    @State private var dialog: SidebarDialog?
    @State private var budgetCategory: IDBox?
    /// Row a drag is hovering over (drop highlight).
    @State private var dropTarget: String?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.interactiveSidebarSelection) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2").foregroundStyle(Theme.secondary).frame(width: 20)
                Text("Übersicht").fontWeight(.medium)
                Spacer()
            }
            .badge(model.newCount) // system sidebar badge (hidden at 0)
            .tag(SidebarItem.allAccounts)
            HStack(spacing: 8) {
                Image(systemName: "doc.on.doc").foregroundStyle(Theme.secondary).frame(width: 20)
                Text("Belege & PostBox").fontWeight(.medium)
                Spacer()
            }
            .tag(SidebarItem.documents)
            // The MoneyMoney import is an action, not a place: it lives in
            // Ablage › Aus MoneyMoney importieren …, the command palette and
            // the welcome card (HIG: sidebar rows are navigation destinations).

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
                Section("Neue Bankzugänge") {
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
                            .disabled(model.bankingGate(for: c) != nil)
                            .help(model.bankingGate(for: c)?.message ?? "")
                    }
                    .contextMenu {
                        Button("Bankzugang entfernen …", systemImage: "trash", role: .destructive) { dialog = .removeConnection(c.id) }
                    }
                }
                }
            }

            Section {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.folder").foregroundStyle(Theme.warning).frame(width: 20)
                    Text("Ohne Kategorie")
                    Spacer()
                }
                .badge(model.uncategorizedCount)
                .tag(SidebarItem.uncategorized)
                categoryRows(model.categoryTree)
            } header: {
                HStack(spacing: 4) {
                    Text("Kategorien").font(.caption.weight(.semibold))
                    Spacer()
                    Button { model.newCategoryRequest = NewCategoryRequest(parent: nil) } label: {
                        Image(systemName: "plus").frame(width: 24, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.secondary)
                    .help("Neue Hauptkategorie …")
                    .accessibilityLabel("Neue Hauptkategorie")
                    .disabled(model.vault == nil)
                }
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
                }
                Spacer(minLength: 0)
                Button { model.showAddBank = true } label: {
                    Image(systemName: "plus").frame(width: 24, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Bank hinzufügen …")
                .accessibilityLabel("Bank hinzufügen")
                .disabled(model.vault == nil)
            }
            .font(.caption)
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
        .confirmationDialog(
            dialog?.title ?? Text(verbatim: ""),
            isPresented: Binding(get: { dialog != nil }, set: { if !$0 { dialog = nil } }),
            titleVisibility: .visible,
            presenting: dialog
        ) { d in
            switch d {
            case .archiveAccount(let a): Button("Archivieren") { model.setAccountArchived(a, true) }
            case .deleteAccount(let a): Button("Endgültig löschen", role: .destructive) { model.deleteAccount(a.id) }
            case .removeConnection(let id): Button("Entfernen", role: .destructive) { model.removeConnection(id) }
            case .deleteCategory(let c): Button("„\(c.name)“ löschen", role: .destructive) { model.deleteCategory(c.id) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { d in
            switch d {
            case .archiveAccount(let a):
                Text("„\(a.name)“ wird nicht mehr abgerufen, von Regeln nicht mehr verändert und zählt nicht mehr zur Gesamtsumme. Buchungen, Kategorien, Belege und die Gruppe bleiben erhalten. Das Konto lässt sich jederzeit reaktivieren.")
            case .deleteAccount(let a):
                Text("„\(a.name)“ wird samt \(a.transactionCount) Buchungen, Belegen und Depotpositionen unwiderruflich gelöscht – auch aus Auswertungen und Kategoriesummen. Ist es das letzte Konto seines Bankzugangs, wird auch der Bankzugang mit den gespeicherten Zugangsdaten entfernt.")
            case .removeConnection:
                Text("Alle Konten dieses Bankzugangs werden samt Buchungen, Belegen und gespeicherten Zugangsdaten aus dem Tresor gelöscht. Das lässt sich nicht widerrufen.")
            default: EmptyView()
            }
        }
        .sheet(item: $budgetCategory) { box in BudgetEditorSheet(categoryID: box.id).environment(model) }
    }

    /// "Nach Kontoart": the fixed kind sections.
    @ViewBuilder
    private var kindGroupRows: some View {
        ForEach(model.groups) { group in
            let open = !model.collapsedGroups.contains(group.id)
            let toggle = {
                withAnimation(Motion.animation(.easeInOut(duration: 0.15))) {
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
                    Button("Gruppenübersicht", systemImage: "list.bullet.rectangle") { model.interactiveSidebarSelection = .group(group.id) }
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
            let toggle = { withAnimation(Motion.animation(.easeInOut(duration: 0.15))) { model.toggleCollapsed(group) } }
            let indent = CGFloat(group.depth) * 14
            UserGroupHeader(group: group, open: open, toggle: toggle)
                .padding(.top, group.depth == 0 ? 10 : 4)
                .padding(.leading, indent)
                .groupHeaderTap(SidebarItem.userGroup(group.uuid), toggle: toggle)
                .contextMenu {
                    UserGroupMenu(group: group)
                }
                .popover(isPresented: model.iconColorBinding(.group(group.uuid)), arrowEdge: .trailing) {
                    IconColorPopover(target: .group(group.uuid)).environment(model)
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
                        // one step right of their group, at every nesting level
                        .padding(.leading, indent + 14)
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
            .popover(isPresented: model.iconColorBinding(.account(account.id)), arrowEdge: .trailing) {
                IconColorPopover(target: .account(account.id)).environment(model)
            }
            #if os(iOS)
            .swipeActions(edge: .trailing) {
                Button("Gruppe …", systemImage: "folder") { model.groupDialog = .moveAccount(account) }
                    .tint(Theme.accent)
            }
            #endif
    }

    @ViewBuilder
    private func accountMenu(_ account: Account) -> some View {
        // same order as a group's menu: rename, look, place – then what only
        // accounts have – then archive / delete
        Button("Umbenennen …", systemImage: "pencil") { model.groupDialog = .renameAccount(account) }
        Button("Symbol & Farbe …", systemImage: "paintpalette") { model.iconColorTarget = .account(account.id) }
        AccountGroupMenu(account: account)
        Divider()
        ManualLoanAccountMenu(model: model, account: account)
        if !account.isArchived, let cid = account.connectionId, let conn = model.connections.first(where: { $0.id == cid }) {
            Button("\(conn.displayName) abrufen", systemImage: "arrow.triangle.2.circlepath") { model.requestSync(conn) }
                .disabled(model.bankingGate(for: conn) != nil)
        }
        if !account.iban.isEmpty {
            Button("IBAN kopieren", systemImage: "doc.on.doc") { copyToPasteboard(account.iban) }
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

    /// The category tree at any depth (#101): a node with sub-categories is a
    /// disclosure group whose content recurses into its children.
    private func categoryRows(_ nodes: [CategoryNode]) -> AnyView {
        AnyView(ForEach(nodes) { node in
            if let kids = node.children {
                DisclosureGroup(isExpanded: Binding(
                    get: { model.expandedCategories.contains(node.id) },
                    set: { if $0 { model.expandedCategories.insert(node.id) } else { model.expandedCategories.remove(node.id) } }
                )) {
                    categoryRows(kids)
                } label: {
                    CategoryRow(category: node.category)
                        .contextMenu { categoryMenu(node.category) }
                }
                .tag(SidebarItem.category(node.id))
            } else {
                CategoryRow(category: node.category)
                    .tag(SidebarItem.category(node.id))
                    .contextMenu { categoryMenu(node.category) }
            }
        })
    }

    @ViewBuilder
    private func categoryMenu(_ category: GiroCrabCore.Category) -> some View {
        Button("Neue Unterkategorie …", systemImage: "plus") { model.newCategoryRequest = NewCategoryRequest(parent: category.id) }
        Button("Neue Hauptkategorie …", systemImage: "plus.square") { model.newCategoryRequest = NewCategoryRequest(parent: nil) }
        Button("Monatsbudget festlegen …", systemImage: "gauge.with.dots.needle.67percent") { budgetCategory = IDBox(id: category.id) }
        Divider()
        Button("„\(category.name)“ löschen …", systemImage: "trash", role: .destructive) { dialog = .deleteCategory(category) }
    }
}

struct SectionHeader: View {
    @Environment(AppModel.self) private var model
    /// Selected header: hierarchical styles so macOS can draw them light on the
    /// accent-coloured selection (fixed theme colours stay dark there).
    private var selected: Bool { model.sidebarSelection == SidebarItem.group(group.id) }
    let group: AccountGroup
    var open: Bool = true
    var toggle: () -> Void = {}

    var body: some View {
        HStack(spacing: 5) {
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 12, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(open ? "„\(group.name)“ einklappen" : "„\(group.name)“ ausklappen")
            .accessibilityValue(open ? "Ausgeklappt" : "Eingeklappt")
            Text(group.name)
            Spacer()
            Text(Money.format(group.balanceCents))
                .monospacedDigit()
                .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(group.balanceCents < 0 && isLoanGroup ? Theme.loan : (group.balanceCents < 0 ? Theme.negative : Theme.secondary)))
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }
}

extension SectionHeader {
    /// Loan groups are recognised by their accounts, not by the (translated) group name.
    var isLoanGroup: Bool { !group.accounts.isEmpty && group.accounts.allSatisfy { $0.kind == .loan } }
}

struct AccountRow: View {
    @Environment(AppModel.self) private var model
    /// Selected row: the amount uses the hierarchical `.primary` style, which
    /// macOS turns white on the accent-coloured selection (fixed theme colours
    /// stay dark there). `backgroundProminence` is not set in a macOS sidebar.
    private var onSelection: Bool { model.sidebarSelection == .account(account.id) }
    let account: Account
    var syncing: Bool = false

    private var repaid: Double? {
        guard account.kind == .loan, let p = account.initialBalanceCents, p > 0 else { return nil }
        return max(0, min(1, 1 - Double(-account.balanceCents) / Double(p)))
    }

    var body: some View {
        HStack(spacing: 9) {
            // tinted like the account's marker in the booking list
            AccountSignet(account: account, size: 24, color: model.accountColor(account.id), onSelection: onSelection)
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
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        .help("Archiviert – wird nicht mehr abgerufen")
                } else {
                    Text(account.bankName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if syncing {
                ProgressView().controlSize(.mini)
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text(Money.format(account.balanceCents, currency: account.currency))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(onSelection ? AnyShapeStyle(.primary) : AnyShapeStyle(account.kind == .loan ? Theme.loan : (account.balanceCents < 0 ? Theme.negative : Theme.text)))
                if let repaid {
                    Text("\(repaid.formatted(.percent.precision(.fractionLength(0)))) getilgt").font(.caption2).foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary) // follows selection, Dark Mode, Increase Contrast
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

    var title: Text {
        switch self {
        case .archiveAccount: Text("Konto archivieren?")
        case .deleteAccount: Text("Archiviertes Konto endgültig löschen?")
        case .removeConnection: Text("Bankzugang entfernen?")
        case .deleteCategory: Text("Kategorie löschen?")
        }
    }
}
