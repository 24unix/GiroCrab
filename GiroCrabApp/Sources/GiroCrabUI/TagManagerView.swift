#if os(macOS)
import SwiftUI
import GiroCrabCore

/// Konten › Tags verwalten … (#228, part 2b): every tag with its booking count;
/// rename, colour, order, merge, delete. A sheet of the main window with a fixed
/// size (names never exceed 64 characters), so the rest of the app waits while it
/// is open. Sheets are never part of a bug report screenshot; tag names stay
/// marked `.sensitive()` all the same.
struct TagManagerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.textScale) private var textScale
    @State private var selection: Set<Int64> = []
    @State private var search = ""
    @State private var editor: TagNameEditor.Mode?
    @State private var merging = false
    @State private var confirmDelete = false
    @State private var confirmUnused = false
    private enum Focus: Hashable { case list, search }
    @FocusState private var focus: Focus?
    /// ⌘N while the sheet is up (see `watchKeys`).
    @State private var keyMonitor: Any?

    /// The tags as the sheet shows them: with the names and colours changed here
    /// (`model.tagDraft`, stored when the sheet is dismissed). Checks and dialogs
    /// in the sheet use these.
    private var current: [GiroCrabCore.Tag] { AppModel.tagsDrafted(model.tags, model.tagDraft) }

    /// The tags in the sheet's order: the pending arrangement, tags new since then after it.
    private var ordered: [GiroCrabCore.Tag] {
        let tags = current
        guard let order = model.tagDraft.order else { return tags }
        let byID = Dictionary(tags.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return AppModel.tagOrder(order, tags: tags).compactMap { byID[$0] }
    }

    private var shown: [GiroCrabCore.Tag] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return ordered }
        let loose = AppModel.tagLookAlikeKey(q)
        return ordered.filter {
            $0.name.localizedCaseInsensitiveContains(q) || (!loose.isEmpty && AppModel.tagLookAlikeKey($0.name).contains(loose))
        }
    }

    private var selected: [GiroCrabCore.Tag] { current.filter { selection.contains($0.id) } }

    /// Merging needs at least two selected tags; the sheet then asks which one stays.
    private var canMerge: Bool { selection.count > 1 }

    private var move: ((IndexSet, Int) -> Void)? {
        guard search.isEmpty else { return nil }
        return { from, to in
            var ids = ordered.map(\.id)
            ids.move(fromOffsets: from, toOffset: to)
            model.tagDraft.order = ids
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            if model.tags.isEmpty {
                ContentUnavailableView {
                    Label("Noch keine Tags", systemImage: "number")
                } description: {
                    Text("Tags vergeben Sie in der rechten Seitenleiste einer Buchung oder per Rechtsklick in der Buchungsliste.")
                } actions: {
                    Button("Neuer Tag …") { editor = .create }
                }
                .frame(maxHeight: .infinity)
            } else {
                header
                list
            }
            Divider()
            bottomBar
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if let pending = pendingHint {
                        pending
                            .appFont(.caption)
                            .foregroundStyle(Theme.secondary)
                    }
                    // the keys this sheet answers to, quietly
                    Text("⌘N Neuer Tag · ↩ Umbenennen · ⌫ Löschen · esc Auswahl aufheben")
                        .appFont(.caption2)
                        .foregroundStyle(Theme.tertiary)
                }
                Spacer()
                // no Return shortcut: Return renames the selected tag
                Button("Schließen") { dismiss() }
            }
            .padding(12)
        }
        .frame(width: 560 * textScale, height: 520 * textScale)
        .background {
            // Esc: leaves the search field (clearing it), then clears the
            // selection, then closes the sheet
            Button("") {
                if focus == .search {
                    search = ""
                    focus = .list
                } else if !selection.isEmpty {
                    selection = []
                } else {
                    dismiss()
                }
            }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .capturableSheet(item: $editor) { mode in
            TagNameEditor(mode: mode, tags: current, create: create) { id, name in model.tagDraft.renames[id] = name }
        }
        .capturableSheet(isPresented: $merging) { TagMergeSheet(sources: selection, tags: current) { selection = [$0] } }
        .capturableSheet(isPresented: $confirmUnused) { TagUnusedSheet(tags: current) }
        .confirmationDialog(deleteTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                model.deleteTags(selection)
                selection = []
            }
        } message: {
            deleteMessage
        }
        // a tag gone (merged, deleted, synced away) leaves the selection
        .onChange(of: model.tags.map(\.id)) { _, ids in selection.formIntersection(ids) }
        .onAppear(perform: watchKeys)
        .onDisappear(perform: unwatchKeys)
        .defaultFocus($focus, .list)
        .task {
            // AppKit makes the search field (the first text field) the first
            // responder once the sheet is up; take the focus back to the list
            try? await Task.sleep(for: .milliseconds(80))
            focus = .list
        }
        // locking the vault closes the sheet
        .onChange(of: model.isUnlocked) { _, open in if !open { dismiss() } }
    }

    private var titleBar: some View {
        HStack(spacing: 12) {
            Text("Tags verwalten").appFont(.headline)
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                TextField("Tags durchsuchen", text: $search)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .search)
                    .appFont(.body)
                    .sensitive()
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary))
            .frame(width: 200 * textScale)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var header: some View {
        HStack {
            Text("Tag")
            Spacer()
            Text("Buchungen")
        }
        .appFont(.caption, weight: .semibold)
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 2)
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(shown, id: \.id) { t in
                TagManagerRow(tag: t, movable: move != nil)
                    .tag(t.id)
            }
            // drag to reorder; not while searching (the list is only a part then)
            .onMove(perform: move)
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            if ids.count == 1, let id = ids.first {
                Button("Umbenennen …") { editor = .rename(id) }
            }
            if ids.count > 1 {
                Button("Zusammenführen …") { selection = ids; merging = true }
            }
            if !ids.isEmpty {
                Divider()
                Button(ids.count > 1 ? "\(ids.count) Tags löschen …" : "Löschen …", role: .destructive) {
                    selection = ids
                    confirmDelete = true
                }
            }
        } primaryAction: { ids in
            // double-click: rename
            if ids.count == 1, let id = ids.first { editor = .rename(id) }
        }
        .focused($focus, equals: .list)
        .onDeleteCommand { if !selection.isEmpty { confirmDelete = true } }
        // Return: rename the one selected tag (as in Finder)
        .onKeyPress(.return) {
            guard selection.count == 1, let id = selection.first else { return .ignored }
            editor = .rename(id)
            return .handled
        }
    }

    /// +/− square buttons beneath the list (as in the account groups), then the
    /// actions; „Schließen“ has its own row below, so every label fits.
    private var bottomBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                Button { editor = .create } label: {
                    Image(systemName: "plus").frame(width: 26, height: 22).contentShape(Rectangle())
                }
                .help(Text("Neuer Tag … (⌘N)"))
                .accessibilityLabel(Text("Neuer Tag"))
                Divider().frame(height: 16)
                Button { confirmDelete = true } label: {
                    Image(systemName: "minus").frame(width: 26, height: 22).contentShape(Rectangle())
                }
                .disabled(selection.isEmpty)
                .help(Text(selection.count > 1 ? "Ausgewählte Tags löschen …" : "Tag löschen …"))
                .accessibilityLabel(Text("Tag löschen"))
            }
            .buttonStyle(.borderless)
            Button("Zusammenführen …") { merging = true }
                .fixedSize()
                .disabled(!canMerge)
                .help(Text(canMerge ? "Ausgewählte Tags zu einem vereinen" : "Mindestens zwei Tags auswählen (⌘-Klick)"))
            Spacer(minLength: 8)
            Menu("Sortieren") {
                Button("Nach Name") { model.tagDraft.order = AppModel.tagIDsByName(current) }
                Button("Meiste Buchungen zuerst") { model.tagDraft.order = AppModel.tagIDsByBookings(model.tags, mostFirst: true) }
                Button("Wenigste Buchungen zuerst") { model.tagDraft.order = AppModel.tagIDsByBookings(model.tags, mostFirst: false) }
                Divider()
                Text("Oder Tags in der Liste ziehen.")
            }
            .fixedSize()
            .disabled(model.tags.count < 2)
            Button("Ungenutzte entfernen …") { confirmUnused = true }
                .fixedSize()
                .disabled(model.unusedTags.isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// ⌘N (new tag). A sheet's buttons never see it: the main menu takes it first
    /// (its „Neue Überweisung …“, disabled while this sheet is open). So it is
    /// caught before AppKit hands it out, and only while no dialog lies on top.
    private func watchKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  editor == nil, !merging, !confirmUnused, !confirmDelete else { return event }
            guard event.charactersIgnoringModifiers?.lowercased() == "n" else { return event }
            editor = .create
            return nil
        }
    }

    private func unwatchKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private var pendingHint: Text? {
        model.tagDraft.isEmpty ? nil : Text("Neue Namen, Farben und die Reihenfolge gelten, sobald Sie schließen.")
    }

    /// „Neuer Tag …“: right away (it only adds). A name that is free only because a
    /// tag here gets another one needs those names stored first.
    private func create(_ name: String) {
        if model.createTag(named: name) == nil, !model.tagDraft.renames.isEmpty {
            model.applyTagRenames(model.tagDraft.renames)
            model.tagDraft.renames = [:]
            model.createTag(named: name)
        }
    }

    private var deleteTitle: Text {
        if selected.count == 1, let t = selected.first { return Text("„\(t.name)“ löschen?") }
        return Text("\(selected.count) Tags löschen?")
    }

    private var deleteMessage: Text {
        if selected.count == 1, let t = selected.first {
            switch t.bookingCount {
            case 0: return Text("Der Tag ist keiner Buchung zugeordnet.")
            case 1: return Text("Der Tag ist einer Buchung zugeordnet und wird dort entfernt. Die Buchung bleibt.")
            default: return Text("Der Tag ist \(t.bookingCount) Buchungen zugeordnet und wird bei allen entfernt. Die Buchungen bleiben.")
            }
        }
        return Text("Die Tags werden bei allen Buchungen entfernt. Die Buchungen bleiben.")
    }
}

/// „Ungenutzte entfernen …“: the tags without bookings as coloured chips, then
/// one confirmation.
struct TagUnusedSheet: View {
    /// The tags with the names the tag sheet shows.
    let tags: [GiroCrabCore.Tag]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.textScale) private var textScale
    /// Taken on appear, so the chips don't vanish while the sheet closes.
    @State private var unused: [GiroCrabCore.Tag] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            (unused.count == 1 ? Text("1 ungenutzten Tag entfernen?") : Text("\(unused.count) ungenutzte Tags entfernen?"))
                .appFont(.headline)
            Text("Diese Tags sind keiner Buchung zugeordnet.")
                .appFont(.callout)
                .foregroundStyle(Theme.secondary)
            TagChipFlow(tags: unused)
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Entfernen", role: .destructive) {
                    model.removeUnusedTags()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(unused.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440 * textScale)
        .onAppear { unused = tags.filter { $0.bookingCount == 0 } }
    }
}

/// One tag: colour (click: palette), name, booking count.
private struct TagManagerRow: View {
    @Environment(AppModel.self) private var model
    let tag: GiroCrabCore.Tag
    /// Shows the grip; off while searching (then the list can't be reordered).
    let movable: Bool
    @State private var choosingColor = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.tertiary)
                .opacity(movable ? 1 : 0)
                .help(Text("Zum Verschieben ziehen"))
                .accessibilityHidden(true)
            Button { choosingColor = true } label: {
                Circle().fill(tag.colorHex.isEmpty ? Theme.secondary : Color(hex: tag.colorHex))
                    .frame(width: 12, height: 12)
                    .padding(3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Farbe ändern"))
            .capturablePopover(isPresented: $choosingColor, arrowEdge: .bottom) {
                // stored when the sheet closes, like names and order
                TagColorPalette(current: tag.colorHex, pick: { hex in
                    model.tagDraft.colors[tag.id] = hex
                    choosingColor = false
                }, custom: { hex in
                    // the colour panel sends every change; the popover stays open
                    model.tagDraft.colors[tag.id] = hex
                })
            }
            Text(tag.name)
                .appFont(.body)
                .lineLimit(2)
                .sensitive()
            Spacer(minLength: 8)
            Text(tag.bookingCount, format: .number)
                .appFont(.callout, monospacedDigit: true)
                .foregroundStyle(tag.bookingCount == 0 ? Theme.tertiary : Theme.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// The palette new tags take their colours from, plus „keine Farbe“.
struct TagColorPalette: View {
    let current: String
    let pick: (String) -> Void
    /// Any other colour from the system colour panel (like categories and groups).
    var custom: ((String) -> Void)?

    static let names: [String: LocalizedStringResource] = [
        "#2E86DE": "Blau", "#27AE60": "Grün", "#E67E22": "Orange", "#8E44AD": "Violett",
        "#C0392B": "Rot", "#16A085": "Türkis", "#D4AC0D": "Gelb", "#7F8C8D": "Grau",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(AppModel.tagPalette, id: \.self) { hex in
                    Button { pick(hex) } label: {
                        Circle().fill(Color(hex: hex))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(.primary, lineWidth: current.uppercased() == hex ? 2 : 0).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help(Self.names[hex].map { Text($0) } ?? Text(verbatim: hex))
                }
            }
            HStack(spacing: 12) {
                Button("Keine Farbe") { pick("") }
                    .buttonStyle(.link)
                    .appFont(.caption)
                    .disabled(current.isEmpty)
                Spacer(minLength: 8)
                if let custom {
                    Text("Eigene Farbe").appFont(.caption).foregroundStyle(Theme.secondary)
                    ColorPicker("Eigene Farbe", selection: Binding(
                        get: { current.isEmpty ? Theme.accent : Color(hex: current) },
                        set: { if let hex = $0.hexRGB { custom(hex) } }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 26, height: 20)
                    .help("Weitere Farben aus dem Farbfenster")
                }
            }
        }
        .padding(12)
    }
}

/// „Neuer Tag …“ / „Umbenennen …“: the name, with the same hints as the tag field.
struct TagNameEditor: View {
    enum Mode: Identifiable, Hashable {
        case create
        case rename(Int64)
        var id: Self { self }
    }

    let mode: Mode
    /// The tags with the names the tag sheet shows; checks run against these.
    let tags: [GiroCrabCore.Tag]
    let create: (String) -> Void
    let rename: (Int64, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.textScale) private var textScale
    @State private var name = ""
    /// Set on save: the sheet keeps its last look while it closes instead of
    /// reporting the name it just created as taken.
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            title.appFont(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .appFont(.body)
                .sensitive()
                .overlay {
                    if let edge = check.edge {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(edge, lineWidth: 1.5)
                    }
                }
                .onSubmit(save)
            if let hint = check.hint {
                hint.appFont(.caption)
                    .foregroundStyle(check.edge ?? Theme.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .sensitive()
            }
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!check.canSave)
            }
        }
        .padding(20)
        .frame(width: 380 * textScale)
        .onAppear {
            if case .rename(let id) = mode { name = tags.first { $0.id == id }?.name ?? "" }
        }
    }

    private var title: Text {
        switch mode {
        case .create: Text("Neuer Tag")
        case .rename: Text("Tag umbenennen")
        }
    }

    private var confirmTitle: LocalizedStringKey {
        switch mode {
        case .create: "Anlegen"
        case .rename: "Umbenennen"
        }
    }

    private struct Check {
        var canSave = false
        var hint: Text?
        var edge: Color?
    }

    private var check: Check {
        if saved { return Check(canSave: true) }
        switch mode {
        case .create:
            switch AppModel.tagEntryIntent(name, tags: tags, carried: []) {
            case .none: return Check()
            case .create: return Check(canSave: true)
            case .add(_, let existing), .already(let existing):
                return Check(hint: Text("„\(existing)“ gibt es schon."), edge: Theme.warning)
            case .similar(_, _, let existing):
                return Check(canSave: true, hint: Text("Ähnlich wie „\(existing)“."), edge: Theme.warning)
            case .tooLong:
                return Check(hint: Text("Höchstens \(AppModel.maxTagNameLength) Zeichen"), edge: Theme.negative)
            }
        case .rename(let id):
            switch AppModel.tagRenameIntent(name, tags: tags, renaming: id) {
            case .empty, .unchanged: return Check()
            case .rename: return Check(canSave: true)
            case .taken(let other):
                return Check(hint: Text("„\(other)“ gibt es schon. Um beide zu vereinen: „Zusammenführen …“."),
                             edge: Theme.warning)
            case .similar(_, let existing):
                return Check(canSave: true, hint: Text("Ähnlich wie „\(existing)“."), edge: Theme.warning)
            case .tooLong:
                return Check(hint: Text("Höchstens \(AppModel.maxTagNameLength) Zeichen"), edge: Theme.negative)
            }
        }
    }

    private func save() {
        guard !saved, check.canSave else { return }
        saved = true
        switch mode {
        case .create: create(name)
        case .rename(let id): rename(id, AppModel.cleanTagName(name))
        }
        dismiss()
    }
}

/// „Zusammenführen …“ (two or more tags selected): the tag that stays (preset:
/// the one with the most bookings) and the ones that go into it, as chips; a
/// click on one of those keeps it instead.
struct TagMergeSheet: View {
    let sources: Set<Int64>
    /// The tags with the names the tag sheet shows.
    let tags: [GiroCrabCore.Tag]
    /// Called with the tag that stays, so the window can select it.
    let merged: (Int64) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.textScale) private var textScale
    @State private var target: Int64?
    /// Taken on appear, so the sheet keeps its look while it closes.
    @State private var choices: [GiroCrabCore.Tag] = []

    private var staying: GiroCrabCore.Tag? { choices.first { $0.id == target } }
    private var leaving: [GiroCrabCore.Tag] { choices.filter { $0.id != target } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tags zusammenführen").appFont(.headline)
                Text("Ein Tag bleibt und übernimmt die Buchungen der anderen. Um einen anderen zu behalten, klicken Sie ihn an.")
                    .appFont(.callout)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let staying {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bleibt").appFont(.caption, weight: .semibold).foregroundStyle(Theme.secondary)
                    TagChipFlow(tags: [staying], highlighted: true)
                }
                if !leaving.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        (leaving.count == 1
                            ? Text("Geht in „\(staying.name)“ auf")
                            : Text("Gehen in „\(staying.name)“ auf (\(leaving.count))"))
                            .appFont(.caption, weight: .semibold)
                            .foregroundStyle(Theme.secondary)
                            .sensitive()
                        TagChipFlow(tags: leaving, maxHeight: 140, tapHelp: Text("Stattdessen diesen Tag behalten")) {
                            target = $0.id
                        }
                    }
                    summary(staying: staying)
                        .appFont(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .sensitive()
                }
            }
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Zusammenführen") {
                    guard let target else { return }
                    model.mergeTags(sources, into: target)
                    merged(target)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(staying == nil || leaving.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440 * textScale)
        .onAppear {
            choices = tags.filter { sources.contains($0.id) }
            target = choices.max { $0.bookingCount < $1.bookingCount }?.id
        }
    }

    private func summary(staying t: GiroCrabCore.Tag) -> Text {
        if leaving.count == 1, let one = leaving.first {
            return Text("„\(t.name)“ bleibt und übernimmt die Buchungen von „\(one.name)“. „\(one.name)“ wird danach gelöscht. Das lässt sich nicht widerrufen.")
        }
        return Text("„\(t.name)“ bleibt und übernimmt die Buchungen der anderen \(leaving.count) Tags. Diese werden danach gelöscht. Das lässt sich nicht widerrufen.")
    }
}

/// Tags as coloured chips that wrap; scrolls only beyond `maxHeight` (scaled).
/// With `onTap` the chips are buttons.
struct TagChipFlow: View {
    let tags: [GiroCrabCore.Tag]
    var maxHeight: CGFloat = 200
    var highlighted = false
    var tapHelp: Text?
    var onTap: ((GiroCrabCore.Tag) -> Void)?
    @Environment(\.textScale) private var textScale
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            TagFlow {
                ForEach(tags, id: \.id) { t in
                    TagChip(name: t.name, colorHex: t.colorHex, highlighted: highlighted,
                            onTap: onTap.map { tap in { tap(t) } })
                        .help(onTap == nil ? Text(verbatim: "") : tapHelp ?? Text(verbatim: ""))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        // as tall as the chips (a ScrollView has no height of its own)
        .frame(height: min(max(height, 20), maxHeight * textScale))
    }
}
#endif
