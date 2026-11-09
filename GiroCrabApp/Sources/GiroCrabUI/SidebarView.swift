import SwiftUI
import GiroCrabCore

/// Column 1: collapsible account sections with subtotals, then categories.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var newCategoryParent: Int64?? = nil
    @State private var newCategoryName = ""

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
            Button { model.showMoneyMoneyImport = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down.on.square").foregroundStyle(Theme.secondary).frame(width: 20)
                    Text("MoneyMoney-Import").fontWeight(.medium)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            ForEach(model.groups) { group in
                let open = !model.collapsedGroups.contains(group.id)
                // Plain rows instead of List sections: macOS would otherwise
                // restore its own saved collapse state for sidebar sections.
                SectionHeader(group: group, open: open) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if open { model.collapsedGroups.insert(group.id) } else { model.collapsedGroups.remove(group.id) }
                    }
                }
                .padding(.top, 10)
                .tag(SidebarItem.group(group.id))
                ForEach(open ? group.accounts : []) { account in
                    AccountRow(account: account, syncing: model.syncingConnectionID != nil && model.syncingConnectionID == account.connectionId)
                        .tag(SidebarItem.account(account.id))
                        .contextMenu { accountMenu(account) }
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
                .foregroundStyle(group.balanceCents < 0 && isLoanGroup ? Theme.loan : (group.balanceCents < 0 ? Color(hex: "#B91C1C") : Theme.secondary))
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
                    .foregroundStyle(account.kind == .loan ? Theme.loan : (account.balanceCents < 0 ? Color(hex: "#B91C1C") : Theme.text))
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
                .foregroundStyle(Color(hex: category.colorHex).opacity(0.85))
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
