import SwiftUI
import GiroCrabCore

// MARK: - Drag payloads (plain strings, so no custom UTType is needed)

enum GroupDrag {
    static let accountPrefix = "girocrab-account:"
    static let groupPrefix = "girocrab-group:"

    static func account(_ id: Int64) -> String { accountPrefix + String(id) }
    static func group(_ uuid: String) -> String { groupPrefix + uuid }

    static func accountID(_ s: String) -> Int64? {
        s.hasPrefix(accountPrefix) ? Int64(s.dropFirst(accountPrefix.count)) : nil
    }

    static func groupUUID(_ s: String) -> String? {
        s.hasPrefix(groupPrefix) ? String(s.dropFirst(groupPrefix.count)) : nil
    }
}

// MARK: - Sidebar pieces

/// "Konten" title with visible group actions and the view switch.
/// The switch is a segmented control (a choice of how the list is
/// organised, not a filter); new group and editing are buttons, not
/// hidden in a menu.
struct AccountsSectionHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Text("Konten")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                if model.accountView == .byGroup {
                    // folder symbols: these act on groups, not on accounts
                    Button { model.groupDialog = .create() } label: {
                        Image(systemName: "folder.badge.plus").frame(width: 24, height: 18).contentShape(Rectangle())
                    }
                    .help("Neue Gruppe …")
                    .accessibilityLabel("Neue Gruppe")
                    Button { model.openGroupSettings() } label: {
                        Image(systemName: "folder.badge.gearshape").frame(width: 24, height: 18).contentShape(Rectangle())
                    }
                    .help("Gruppen bearbeiten …")
                    .accessibilityLabel("Gruppen bearbeiten")
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.secondary)
            Picker("Konten anzeigen nach", selection: $model.accountView) {
                Text("Gruppen").tag(AccountSidebarMode.byGroup)
                Text("Kontoart").tag(AccountSidebarMode.byKind)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.top, 12)
    }
}

/// Header of a user group: chevron, symbol, name, sum.
struct UserGroupHeader: View {
    let group: UserGroup
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
            .accessibilityLabel(open ? "Gruppe einklappen" : "Gruppe ausklappen")
            Image(systemName: group.sfSymbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.tertiary)
                .frame(width: 14)
            Text(group.name).lineLimit(1)
            if !group.includeInTotal {
                Image(systemName: "eye.slash")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiary)
                    .help("Nicht in der Gesamtsumme")
                    .accessibilityLabel("Nicht in der Gesamtsumme")
            }
            Spacer()
            Text(Money.format(group.balanceCents))
                .monospacedDigit()
                .foregroundStyle(group.balanceCents < 0 ? Theme.negative : Theme.secondary)
                .opacity(group.includeInTotal ? 1 : 0.6)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Theme.secondary)
    }
}

/// "Gruppe ▸" submenu for an account (both sidebar views).
struct AccountGroupMenu: View {
    @Environment(AppModel.self) private var model
    let account: Account

    var body: some View {
        Menu("Gruppe", systemImage: "folder") {
            ForEach(model.namedUserGroups) { g in
                Toggle(isOn: Binding(
                    get: { account.userGroupUuid == g.uuid },
                    set: { _ in model.moveAccount(account.id, to: g.uuid) }
                )) {
                    Label(g.name, systemImage: g.sfSymbol)
                }
            }
            Toggle(isOn: Binding(
                get: { account.userGroupUuid == nil },
                set: { _ in model.moveAccount(account.id, to: nil) }
            )) {
                Label("Ohne Gruppe", systemImage: "tray")
            }
            Divider()
            Button("Neue Gruppe …", systemImage: "folder.badge.plus") { model.groupDialog = .create(movingAccount: account.id) }
        }
    }
}

/// "Farbe ▸" for an account: the core's palette as colour swatches.
struct AccountColorMenu: View {
    @Environment(AppModel.self) private var model
    let account: Account

    private static let palette = accountColorPalette()
    private static let names: [String: LocalizedStringKey] = [
        "#2563EB": "Blau", "#D97706": "Bernstein", "#059669": "Grün", "#DB2777": "Pink",
        "#7C3AED": "Violett", "#0891B2": "Cyan", "#DC2626": "Rot", "#65A30D": "Limette",
        "#C026D3": "Fuchsia", "#EA580C": "Orange", "#4F46E5": "Indigo", "#0D9488": "Petrol",
    ]

    var body: some View {
        Menu("Farbe", systemImage: "paintpalette") {
            Picker("Farbe", selection: Binding(
                get: { account.colorHex.uppercased() },
                set: { model.setAccountColor(account.id, hex: $0) }
            )) {
                ForEach(Self.palette, id: \.self) { hex in
                    Label(Self.names[hex] ?? LocalizedStringKey(hex), systemImage: "circle.fill")
                        .tint(Color.readable(hex: hex))
                        .tag(hex)
                }
            }
            .pickerStyle(.palette)
            Button("Standardfarbe", systemImage: "arrow.uturn.backward") { model.setAccountColor(account.id, hex: nil) }
        }
    }
}

/// Context menu of a user group header.
struct UserGroupMenu: View {
    @Environment(AppModel.self) private var model
    let group: UserGroup

    var body: some View {
        #if os(iOS)
        Button("Gruppenübersicht", systemImage: "list.bullet.rectangle") { model.sidebarSelection = .userGroup(group.uuid) }
        #endif
        if !group.isUngrouped {
            Button("Umbenennen …", systemImage: "pencil") { model.groupDialog = .rename(group) }
            Menu("Symbol", systemImage: group.sfSymbol) {
                ForEach(GroupSymbols.named, id: \.symbol) { item in
                    Toggle(isOn: Binding(
                        get: { item.symbol == group.sfSymbol },
                        set: { _ in model.updateUserGroup(group, symbol: item.symbol) }
                    )) {
                        Label(item.name, systemImage: item.symbol)
                    }
                }
            }
            Toggle(isOn: Binding(
                get: { group.includeInTotal },
                set: { model.updateUserGroup(group, includeInTotal: $0) }
            )) {
                Label("In Gesamtsumme einbeziehen", systemImage: "sum")
            }
        }
        Divider()
        Button("Neue Gruppe …", systemImage: "folder.badge.plus") { model.groupDialog = .create() }
        Button("Gruppen bearbeiten …", systemImage: "slider.horizontal.3") { model.openGroupSettings() }
        if !group.isUngrouped {
            Divider()
            Button("Gruppe löschen …", systemImage: "trash", role: .destructive) { model.groupDialog = .delete(group) }
        }
    }
}

// MARK: - Dialogs (one place for all group dialogs)

/// Presents a group dialog (new / rename / delete / move account) from the
/// given state. The main window passes `model.groupDialog`; the settings
/// pane passes its own state, so each window shows its own dialogs.
struct AccountGroupDialogs: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var dialog: GroupDialog?
    @State private var text = ""

    /// Shown while the dialog is of this kind; dismissing clears it unless
    /// an action already switched to another dialog.
    private func presented(text wantsText: Bool) -> Binding<Bool> {
        Binding(
            get: { dialog?.needsText == wantsText },
            set: { if !$0, dialog?.needsText == wantsText { dialog = nil } }
        )
    }

    func body(content: Content) -> some View {
        content
            .alert(dialog?.title ?? Text(verbatim: ""), isPresented: presented(text: true), presenting: dialog) { d in
                TextField("Name, z. B. „Privat“ oder „Geschäft“", text: $text)
                Button(d.isRename ? "Umbenennen" : "Anlegen") { submit(d) }
                Button("Abbrechen", role: .cancel) {}
            } message: { d in
                if case .create(let id?) = d, let a = model.account(for: id) {
                    Text("„\(a.name)“ wird in die neue Gruppe verschoben.")
                }
            }
            .confirmationDialog(
                dialog?.title ?? Text(verbatim: ""),
                isPresented: presented(text: false),
                titleVisibility: .visible,
                presenting: dialog
            ) { d in
                switch d {
                case .delete(let g):
                    Button("Löschen", role: .destructive) { model.deleteUserGroup(g) }
                case .moveAccount(let a):
                    ForEach(model.namedUserGroups) { g in
                        Button { model.moveAccount(a.id, to: g.uuid) } label: {
                            Text(verbatim: a.userGroupUuid == g.uuid ? "✓ \(g.name)" : g.name)
                        }
                    }
                    Button { model.moveAccount(a.id, to: nil) } label: {
                        a.userGroupUuid == nil ? Text(verbatim: "✓ ") + Text("Ohne Gruppe") : Text("Ohne Gruppe")
                    }
                    Button("Neue Gruppe …") {
                        // after this dialog has closed
                        DispatchQueue.main.async { dialog = .create(movingAccount: a.id) }
                    }
                case .merge(let from, let into):
                    Button("Zusammenführen") { model.mergeUserGroups(from, into: into) }
                case .create, .rename:
                    EmptyView()
                }
                Button("Abbrechen", role: .cancel) {}
            } message: { d in
                switch d {
                case .delete(let g): Text(deleteMessage(g))
                case .merge(let from, let into):
                    Text("Die Konten aus „\(from.name)“ kommen nach „\(into.name)“. „\(from.name)“ wird entfernt.")
                default: EmptyView()
                }
            }
            .onChange(of: dialog?.initialText) { _, t in text = t ?? "" }
    }

    private func submit(_ d: GroupDialog) {
        let name = text.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        switch d {
        case .create(let accountID): model.createUserGroup(name: name, moving: accountID)
        case .rename(let g):
            // after the alert has closed
            if let next = model.renameUserGroup(g, to: name) { DispatchQueue.main.async { dialog = next } }
        case .delete, .moveAccount, .merge: break
        }
    }
}

extension View {
    func accountGroupDialogs(_ dialog: Binding<GroupDialog?>) -> some View { modifier(AccountGroupDialogs(dialog: dialog)) }
}

/// Settings › "Kontogruppen": list of groups with +/− below it (macOS:
/// details beside it; iOS: pushed). Changes apply immediately, like the
/// rest of Settings – no Done/Cancel.
struct AccountGroupsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?
    /// This window's own group dialog (not the main window's).
    @State private var dialog: GroupDialog?

    private var selectedGroup: UserGroup? {
        selection.flatMap { u in model.namedUserGroups.first { $0.uuid == u } }
    }

    var body: some View {
        content
            .onAppear {
                if selection == nil { selection = model.namedUserGroups.first?.uuid }
            }
            .onChange(of: model.namedUserGroups.map(\.uuid)) { old, new in
                // select a group just created here; leave a deleted one
                if let added = new.first(where: { !old.contains($0) }) {
                    selection = added
                } else if let s = selection, !new.contains(s) {
                    selection = new.first
                }
            }
            .accountGroupDialogs($dialog)
    }

    private var footer: LocalizedStringKey {
        model.hasUserGroups
            ? "Reihenfolge per Ziehen ändern. Konten ohne Gruppe erscheinen unter „Ohne Gruppe“."
            : "Mit Gruppen trennen Sie z. B. private und geschäftliche Konten oder die Konten von Familienmitgliedern."
    }

    #if os(macOS)
    private var content: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(model.namedUserGroups) { g in
                            GroupListRow(group: g).tag(g.uuid)
                        }
                        .onMove { model.moveUserGroups(from: $0, to: $1) }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    Divider()
                    // add/remove square buttons beneath the list (HIG: Buttons › Square buttons)
                    HStack(spacing: 0) {
                        Button { dialog = .create() } label: {
                            Image(systemName: "plus").frame(width: 26, height: 22).contentShape(Rectangle())
                        }
                        .help("Neue Gruppe …")
                        .accessibilityLabel("Neue Gruppe")
                        Divider().frame(height: 16)
                        Button { if let g = selectedGroup { dialog = .delete(g) } } label: {
                            Image(systemName: "minus").frame(width: 26, height: 22).contentShape(Rectangle())
                        }
                        .disabled(selectedGroup == nil)
                        .help("Gruppe löschen …")
                        .accessibilityLabel("Gruppe löschen")
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 2)
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 240)
            Group {
                if let uuid = selectedGroup?.uuid {
                    GroupDetailEditor(uuid: uuid, ask: { dialog = $0 }, onGone: { selection = nil })
                        .id(uuid)
                } else {
                    ContentUnavailableView {
                        Label(model.hasUserGroups ? "Keine Gruppe ausgewählt" : "Noch keine Gruppen", systemImage: "folder")
                    } description: {
                        Text(model.hasUserGroups ? "Wählen Sie links eine Gruppe aus." : "Mit + legen Sie die erste Gruppe an.")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
    }
    #else
    private var content: some View {
        List {
            Section {
                ForEach(model.namedUserGroups) { g in
                    NavigationLink(value: g.uuid) { GroupListRow(group: g) }
                }
                .onMove { model.moveUserGroups(from: $0, to: $1) }
                .onDelete { idx in dialog = idx.first.map { .delete(model.namedUserGroups[$0]) } }
            } footer: {
                Text(footer)
            }
            Section {
                Button("Neue Gruppe …", systemImage: "folder.badge.plus") { dialog = .create() }
            }
        }
        .navigationDestination(for: String.self) { uuid in GroupDetailEditor(uuid: uuid, ask: { dialog = $0 }) }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
    }
    #endif
}

/// A group in the settings list: symbol, name, account count, sum.
struct GroupListRow: View {
    let group: UserGroup

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: group.sfSymbol).foregroundStyle(Theme.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name).lineLimit(1)
                Text(accountCountText(group.accounts.count))
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 4)
            if !group.includeInTotal {
                Image(systemName: "eye.slash").foregroundStyle(Theme.tertiary).help("Nicht in der Gesamtsumme")
            }
        }
        .padding(.vertical, 2)
    }
}

func deleteMessage(_ g: UserGroup) -> String {
    switch g.accounts.count {
    case 0: String(localized: "Die Gruppe ist leer.")
    case 1: String(localized: "Das Konto wird nach „Ohne Gruppe“ verschoben. Es werden keine Konten oder Buchungen gelöscht.")
    case let n: String(localized: "\(n) Konten werden nach „Ohne Gruppe“ verschoben. Es werden keine Konten oder Buchungen gelöscht.")
    }
}

/// "Keine Konten" / "1 Konto" / "3 Konten".
func accountCountText(_ n: Int) -> String {
    switch n {
    case 0: String(localized: "Keine Konten")
    case 1: String(localized: "1 Konto")
    default: String(localized: "\(n) Konten")
    }
}

/// One group: name, symbol, total switch and which accounts belong to it.
struct GroupDetailEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let uuid: String
    /// Shows a confirmation in the pane (delete, or merge on a name clash).
    var ask: (GroupDialog) -> Void
    /// Called when the group disappears (deleted here or via sync);
    /// default: pop back (iOS navigation).
    var onGone: (() -> Void)?
    @State private var name = ""

    private var group: UserGroup? { model.userGroups.first { $0.uuid == uuid } }

    var body: some View {
        if let g = group {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .onSubmit { commitName() }
                }
                Section("Symbol") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 8)], spacing: 8) {
                        ForEach(GroupSymbols.all, id: \.self) { s in
                            Button { model.updateUserGroup(g, symbol: s) } label: {
                                Image(systemName: s)
                                    .font(.system(size: 16))
                                    .frame(width: 38, height: 38)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(s == g.sfSymbol ? Theme.accent.opacity(0.18) : Color.clear))
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(s == g.sfSymbol ? Theme.accent : Theme.tertiary.opacity(0.3)))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(s == g.sfSymbol ? Theme.accent : Theme.secondary)
                            .accessibilityLabel(s)
                            .accessibilityAddTraits(s == g.sfSymbol ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    Toggle("In Gesamtsumme einbeziehen", isOn: Binding(
                        get: { g.includeInTotal },
                        set: { model.updateUserGroup(g, includeInTotal: $0) }
                    ))
                } footer: {
                    Text("Ausgeschaltet zählen die Konten dieser Gruppe nicht zu „Verfügbar“ und zum Saldoverlauf der Übersicht – z. B. für Geschäfts- oder Kinderkonten.")
                }
                Section {
                    ForEach(model.allAccounts) { a in
                        let member = a.userGroupUuid == g.uuid
                        Button {
                            model.moveAccount(a.id, to: member ? nil : g.uuid)
                        } label: {
                            HStack(spacing: 9) {
                                AccountSignet(account: a, size: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(a.name).foregroundStyle(Theme.text)
                                    if !member, let other = model.userGroup(of: a) {
                                        Text("Jetzt in „\(other.name)“").font(.caption2).foregroundStyle(Theme.secondary)
                                    } else {
                                        Text(a.bankName).font(.caption2).foregroundStyle(Theme.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: member ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(member ? Theme.accent : Theme.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(member ? .isSelected : [])
                    }
                } header: {
                    Text("Konten")
                } footer: {
                    Text("Ein Konto gehört zu höchstens einer Gruppe.")
                }
                #if os(iOS)
                Section {
                    Button("Gruppe löschen …", role: .destructive) { ask(.delete(g)) }
                }
                #endif
            }
            .formStyle(.grouped)
            #if os(iOS)
            .navigationTitle(g.name)
            #endif
            .onAppear { name = g.name }
            .onDisappear { commitName() }
        } else {
            // deleted (here or via sync) → back to the list
            Color.clear.onAppear { if let onGone { onGone() } else { dismiss() } }
        }
    }

    /// Saves the edited name, if the group still exists.
    private func commitName() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard let g = group, !n.isEmpty, n != g.name else { return }
        if let merge = model.renameUserGroup(g, to: n) {
            name = g.name
            ask(merge)
        }
    }
}
