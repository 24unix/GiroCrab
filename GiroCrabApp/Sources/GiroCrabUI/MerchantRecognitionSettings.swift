import SwiftUI
import GiroCrabCore

/// Einstellungen › Händler (#1373): the master switch of the merchant recognition, the merchant
/// logos, the user's own merchants and the bundled ones with a switch each. Needs an open vault.
/// Layout and rules: `docs/HAENDLER_UI.md`.
struct MerchantRecognitionSettings: View {
    @Environment(AppModel.self) private var model
    @State private var recognition: MerchantRecognition?
    /// Why the last read failed; the rows of the last good read stay.
    @State private var loadError: String?
    /// Counts the loads: only the newest one may show its result (quick toggles).
    @State private var loads = 0
    @State private var search = ""
    /// Switches flipped here whose write and reload are still running ("" = master switch),
    /// so a toggle does not jump back for the length of a reload.
    @State private var pending: [String: Bool] = [:]
    @State private var editing: MerchantDraft?
    @State private var deleting: CustomMerchant?
    /// Why the last change could not be stored (shown here: an alert of the main window
    /// would hide behind the Settings window).
    @State private var writeError: String?
    /// Position of each bundled merchant in the list, fixed when the pane opens or the search
    /// changes: a switched row must not jump away under the pointer.
    @State private var order: [String: Int] = [:]
    /// Writes still running per switch: a read may only replace a shown switch position
    /// once its write is done.
    @State private var inFlight: [String: Int] = [:]

    private var enabled: Bool { pending[""] ?? recognition?.enabled ?? model.merchantRecognitionEnabled }

    var body: some View {
        Form {
            Section {
                Toggle("Händler erkennen", isOn: Binding(get: { enabled }, set: { setMaster($0) }))
                Text("Erkennt den Händler einer Buchung aus Gegenseite und Verwendungszweck und zeigt seinen Namen und sein Zeichen. Ausgeschaltet zeigen Buchungen die Gegenseite (ohne Gegenseite den Anfang des Verwendungszwecks), ohne Händlernamen und Logo. Was als Konsum, Investition oder wiederkehrende Zahlung zählt, ändert sich dadurch nicht.")
                    .appFont(.caption).foregroundStyle(.secondary)
            } header: { Text("Händlererkennung").appSectionHeader() }
            if let writeError {
                Section {
                    Label("Die Änderung konnte nicht gespeichert werden", systemImage: "exclamationmark.triangle")
                        .appFont(.caption, weight: .semibold).foregroundStyle(Theme.warning)
                    Text(writeError).appFont(.caption2).foregroundStyle(Theme.tertiary).lineLimit(3)
                }
            }
            MerchantLogoSettingsSection()
                .disabled(!enabled)
            if let loadError {
                Section {
                    Label("Die Händlerliste konnte nicht geladen werden", systemImage: "exclamationmark.triangle")
                        .appFont(.caption, weight: .semibold).foregroundStyle(Theme.warning)
                    Text(loadError).appFont(.caption2).foregroundStyle(Theme.tertiary).lineLimit(2)
                    Button("Erneut versuchen") { Task { await reload(sorting: true) } }
                }
            }
            Group {
                Section {
                    TextField("Händler oder Suchwort suchen", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .sensitive() // typed text
                }
                customSection
                builtinSection
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
        // opened, or a vault swap (demo ↔ own): forget the old vault's switches, read and sort
        .task(id: model.vaultRevision) {
            pending = [:]
            await reload(sorting: true)
        }
        // a change here or a merge from another device: read it again, rows stay in place
        .onChange(of: model.merchantSettingsRevision) { Task { await reload(sorting: false) } }
        .onChange(of: search) { sortBuiltin() }
        .capturableSheet(item: $editing) { draft in
            CustomMerchantEditor(draft: draft) { await reload(sorting: false) }
                .environment(model)
        }
        .confirmationDialog(
            Text("„\(deleting?.name ?? "")“ löschen?"),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { m in
            Button("Löschen", role: .destructive) { delete(m) }
            Button("Abbrechen", role: .cancel) {}
        } message: { m in
            Text(deleteMessage(m))
        }
    }

    // MARK: Own merchants

    /// The own merchants the search finds (by name and search word).
    private var customRows: [CustomMerchant] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return (recognition?.custom ?? []).filter { m in
            query.isEmpty
                || m.name.localizedCaseInsensitiveContains(query)
                || m.needles.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    @ViewBuilder private var customSection: some View {
        Section {
            let rows = customRows
            if !search.trimmingCharacters(in: .whitespaces).isEmpty, rows.isEmpty, recognition?.custom.isEmpty == false {
                Text("Kein eigener Händler passt zur Suche.")
                    .appFont(.callout).foregroundStyle(Theme.secondary)
            }
            ForEach(rows, id: \.uuid) { customRow($0) }
            Button {
                editing = MerchantDraft()
            } label: {
                Label("Eigenen Händler hinzufügen …", systemImage: "plus")
            }
        } header: {
            Text("Eigene Händler").appSectionHeader()
        } footer: {
            Text("Eigene Händler gehen den eingebauten vor. Gesucht wird zuerst in der Gegenseite; passen dort mehrere, gewinnt das längste Suchwort. Ein Suchwort passt nur als ganzes Wort (auch mehrere Wörter wie „muster shop“), Groß- und Kleinschreibung zählen nicht. Die Einstellungen gelten auf allen Geräten mit iCloud-Abgleich.")
                .appFont(.footnote)
                .foregroundStyle(.secondary)
                .leadingFooter()
        }
    }

    private func customRow(_ m: CustomMerchant) -> some View {
        HStack(spacing: 10) {
            MerchantSignet(merchant: m.merchant, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(m.name).lineLimit(1)
                    .sensitive() // a name the user typed
                Text(m.needles.joined(separator: ", "))
                    .appFont(.caption).foregroundStyle(Theme.secondary).lineLimit(2)
                    .sensitive()
                if let base = baseName(m) {
                    Text("Kopie von „\(base)“").appFont(.caption2).foregroundStyle(Theme.tertiary)
                }
            }
            Spacer()
            Button { editing = MerchantDraft(m) } label: {
                Label("Bearbeiten …", systemImage: "pencil").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Name und Suchwörter ändern")
            .accessibilityLabel(Text("„\(m.name)“ bearbeiten …"))
            Button(role: .destructive) { deleting = m } label: {
                Label("Löschen …", systemImage: "trash").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Eigenen Händler löschen")
            .accessibilityLabel(Text("„\(m.name)“ löschen …"))
        }
        .contextMenu {
            Button("Bearbeiten …", systemImage: "pencil") { editing = MerchantDraft(m) }
            Button("Löschen …", systemImage: "trash", role: .destructive) { deleting = m }
        }
    }

    // MARK: Bundled merchants

    /// Filtered by name, key and search word, in the order `sortBuiltin` fixed.
    private var builtinRows: [BuiltinMerchant] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let rows = (recognition?.builtin ?? []).filter { m in
            query.isEmpty
                || m.name.localizedCaseInsensitiveContains(query)
                || m.key.localizedCaseInsensitiveContains(query)
                || m.needles.contains { $0.localizedCaseInsensitiveContains(query) }
        }
        return rows.sorted { (order[$0.key] ?? .max) < (order[$1.key] ?? .max) }
    }

    /// Switched-off and replaced ones first (undoing is near), then by name. Only when the
    /// pane opens or the search changes, never after a switch (`order`).
    private func sortBuiltin() {
        let sorted = (recognition?.builtin ?? []).sorted { a, b in
            let (onA, onB) = (isActive(a), isActive(b))
            if onA != onB { return !onA }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        order = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($1.key, $0) })
    }

    private func isOn(_ m: BuiltinMerchant) -> Bool { pending[m.key] ?? m.enabled }

    /// Recognised: switched on and not replaced by an own copy.
    private func isActive(_ m: BuiltinMerchant) -> Bool { isOn(m) && !m.replaced }

    @ViewBuilder private var builtinSection: some View {
        let all = recognition?.builtin ?? []
        let off = all.filter { !isOn($0) }.count
        Section {
            let rows = builtinRows
            if recognition != nil && rows.isEmpty {
                Text("Kein eingebauter Händler passt zur Suche.")
                    .appFont(.callout).foregroundStyle(Theme.secondary)
            }
            ForEach(rows, id: \.key) { builtinRow($0) }
        } header: {
            if off > 0 {
                Text("Eingebaute Händler (\(all.count), \(off) ausgeschaltet)").appSectionHeader()
            } else {
                Text("Eingebaute Händler (\(all.count))").appSectionHeader()
            }
        } footer: {
            Text("Ein ausgeschalteter Händler wird nicht mehr erkannt; die Buchung zeigt dann den nächsten passenden Händler oder ihre Gegenseite. „Bearbeiten“ legt eine Kopie als eigenen Händler an, die den eingebauten ersetzt, solange es sie gibt; die Liste selbst bleibt unverändert.")
                .appFont(.footnote)
                .foregroundStyle(.secondary)
                .leadingFooter()
        }
    }

    private func builtinRow(_ m: BuiltinMerchant) -> some View {
        HStack(spacing: 10) {
            MerchantSignet(merchant: m.merchant, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(m.name).lineLimit(1)
                    .foregroundStyle(isActive(m) ? .primary : Theme.secondary)
                Text(m.needles.joined(separator: ", "))
                    .appFont(.caption).foregroundStyle(Theme.secondary).lineLimit(2)
                if m.replaced {
                    Text("Ersetzt durch eigenen Händler").appFont(.caption2).foregroundStyle(Theme.tertiary)
                }
            }
            Spacer()
            Text(m.kind.title)
                .appFont(.caption).foregroundStyle(Theme.tertiary)
                .lineLimit(1)
            Button { editing = MerchantDraft(copying: m) } label: {
                Label("Bearbeiten …", systemImage: "pencil").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Als eigenen Händler bearbeiten")
            .accessibilityLabel(Text("„\(m.name)“ als eigenen Händler bearbeiten"))
            Toggle(m.name, isOn: Binding(get: { isActive(m) }, set: { setBuiltin(m, $0) }))
                .labelsHidden()
                .disabled(m.replaced)
                .help(m.replaced ? "Ein eigener Händler ersetzt ihn; löschen Sie die Kopie, um ihn wieder zu erkennen."
                      : isOn(m) ? "Diesen Händler nicht mehr erkennen" : "Diesen Händler wieder erkennen")
        }
        .contextMenu {
            Button("Als eigenen Händler bearbeiten …", systemImage: "pencil") { editing = MerchantDraft(copying: m) }
            if !m.replaced {
                Button(isOn(m) ? "Ausschalten" : "Einschalten",
                       systemImage: isOn(m) ? "nosign" : "checkmark.circle") { setBuiltin(m, !isOn(m)) }
            }
        }
    }

    // MARK: Actions

    private func setMaster(_ on: Bool) {
        flip("", to: on) { try await model.setMerchantRecognitionEnabled(on) }
    }

    private func setBuiltin(_ m: BuiltinMerchant, _ on: Bool) {
        flip(m.key, to: on) { try await model.setBuiltinMerchantEnabled(m.key, on) }
    }

    /// Shows the switch `key` in its new position at once and stores it. The list reads
    /// again after the change (`merchantSettingsRevision`); a failed write puts the switch
    /// back, unless it was flipped again meanwhile, and says why.
    private func flip(_ key: String, to on: Bool, _ write: @escaping () async throws -> Void) {
        pending[key] = on
        inFlight[key, default: 0] += 1
        Task {
            defer { inFlight[key] = max(0, (inFlight[key] ?? 1) - 1) }
            do {
                try await write()
                writeError = nil
            } catch {
                if pending[key] == on { pending[key] = nil }
                writeError = describe(error)
                await reload(sorting: false)
            }
        }
    }

    private func delete(_ m: CustomMerchant) {
        Task {
            do {
                try await model.deleteCustomMerchant(m.uuid)
                writeError = nil
            } catch {
                writeError = describe(error)
            }
        }
    }

    private func baseName(_ m: CustomMerchant) -> String? {
        guard !m.basedOn.isEmpty else { return nil }
        return recognition?.builtin.first { $0.key == m.basedOn }?.name ?? m.basedOn
    }

    private func deleteMessage(_ m: CustomMerchant) -> String {
        let otherCopies = (recognition?.custom ?? []).contains { $0.uuid != m.uuid && $0.basedOn == m.basedOn }
        let originalOn = recognition?.builtin.first { $0.key == m.basedOn }?.enabled ?? false
        if let base = baseName(m), !otherCopies, originalOn {
            return String(localized: "Der eingebaute Händler „\(base)“ wird wieder erkannt.")
        }
        return String(localized: "Seine Buchungen zeigen wieder den erkannten Händler oder ihre Gegenseite.")
    }

    /// A load overtaken by a newer one drops its result; a failed one keeps the rows and says so.
    /// A failed write already took its switch out of `pending`. `sorting`: fix the order of
    /// the bundled list anew (see `order`).
    private func reload(sorting: Bool) async {
        loads += 1
        let load = loads
        do {
            let found = try await model.merchantRecognition()
            guard !Task.isCancelled, load == loads else { return }
            guard let found else {
                // locked or switched meanwhile: show nothing of that vault any more
                recognition = nil
                pending = [:]
                order = [:]
                return
            }
            recognition = found
            // a switch keeps its new position only while its write is still running
            pending = pending.filter { key, on in
                inFlight[key, default: 0] > 0
                    && (key.isEmpty ? found.enabled : found.builtin.first { $0.key == key }?.enabled) != on
            }
            if sorting || order.isEmpty { sortBuiltin() }
            loadError = nil
        } catch {
            guard !Task.isCancelled, load == loads else { return }
            loadError = describe(error)
        }
    }
}

/// What the editor of an own merchant starts with.
struct MerchantDraft: Identifiable {
    let id = UUID()
    /// The merchant changed; nil creates one.
    var uuid: String?
    /// Key of the bundled merchant a new one copies.
    var basedOn: String?
    /// Its name, for the hint in the editor.
    var basedOnName: String?
    var name = ""
    var needles = ""

    init() {}

    init(_ m: CustomMerchant) {
        uuid = m.uuid
        name = m.name
        needles = AppModel.merchantNeedlesText(m.needles)
    }

    init(copying m: BuiltinMerchant) {
        basedOn = m.key
        basedOnName = m.name
        name = m.name
        needles = AppModel.merchantNeedlesText(m.needles)
    }
}

/// Name and search words of an own merchant (new, changed or a copy of a bundled one).
struct CustomMerchantEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let draft: MerchantDraft
    /// Runs after a successful save, before the sheet closes (the settings list reloads).
    let onSaved: () async -> Void

    @State private var name = ""
    @State private var needles = ""
    @State private var error: String?
    @State private var saving = false

    private var title: String {
        if draft.uuid != nil { return String(localized: "Händler bearbeiten") }
        if let base = draft.basedOnName { return String(localized: "„\(base)“ als eigenen Händler") }
        return String(localized: "Eigener Händler")
    }

    private var canSave: Bool {
        !saving && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !AppModel.merchantNeedles(needles).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .sensitive()
                    TextField("Suchwörter", text: $needles, prompt: Text("z. B. muster gmbh, muster shop"), axis: .vertical)
                        .lineLimit(2...5)
                        .autocorrectionDisabled()
                        .sensitive()
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Mehrere Suchwörter mit Komma trennen; jedes passt nur als ganzes Wort. Gesucht wird zuerst in der Gegenseite, ohne Gegenseite im Verwendungszweck, bei Zahlungsdiensten auch dahinter (etwa „Ihr Einkauf bei …“).")
                        if let base = draft.basedOnName {
                            Text("Die Kopie behält Logo, Farbe und Art von „\(base)“ und ersetzt den eingebauten Händler, solange es sie gibt.")
                        }
                        if let error {
                            Text(error).foregroundStyle(Theme.warning)
                        }
                    }
                    .appFont(.footnote)
                    .foregroundStyle(.secondary)
                    .leadingFooter()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(draft.uuid == nil ? "Anlegen" : "Sichern") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                }
            }
        }
        #if os(macOS)
        .desktopFrame(minWidth: 460, minHeight: 300)
        #endif
        .onAppear {
            name = draft.name
            needles = draft.needles
        }
    }

    private func save() {
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await model.saveCustomMerchant(uuid: draft.uuid, name: name,
                                                   needles: AppModel.merchantNeedles(needles),
                                                   basedOn: draft.uuid == nil ? draft.basedOn : nil)
                await onSaved()
                dismiss()
            } catch {
                self.error = describe(error)
            }
        }
    }
}

extension MerchantKind {
    /// "Art" of a bundled merchant in Einstellungen › Händler.
    var title: String {
        switch self {
        case .supermarket: String(localized: "Supermarkt")
        case .butcher: String(localized: "Metzgerei")
        case .foodRescue: String(localized: "Lebensmittelrettung")
        case .restaurant: String(localized: "Restaurant")
        case .delivery: String(localized: "Lieferdienst")
        case .drugstore: String(localized: "Drogerie")
        case .insurance: String(localized: "Versicherung")
        case .mobility: String(localized: "Mobilität")
        case .fuel: String(localized: "Tankstelle")
        case .streaming: String(localized: "Streaming")
        case .telecom: String(localized: "Telekommunikation")
        case .utilities: String(localized: "Energie & Versorgung")
        case .onlineShop: String(localized: "Onlineshop")
        case .electronics: String(localized: "Elektronik")
        case .games: String(localized: "Spiele")
        case .fitness: String(localized: "Fitness")
        case .travel: String(localized: "Reisen")
        case .paymentService: String(localized: "Zahlungsdienst")
        case .bank: String(localized: "Bank")
        case .broker: String(localized: "Broker")
        case .etfIssuer: String(localized: "ETF-Anbieter")
        case .etf: String(localized: "ETF")
        case .crypto: String(localized: "Krypto")
        case .stock: String(localized: "Aktie")
        case .unknown: String(localized: "Sonstige")
        }
    }
}
