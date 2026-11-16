import SwiftUI
import GiroCrabCore

/// Wildcard- and token-aware matcher for the rules list filter (#435).
/// Supports `*` (any sequence of characters) and `?` (single character) as well
/// as space-separated tokens, matching case-insensitively across rule name,
/// pattern, and target category path.
enum RuleSearchMatcher {
    static func matches(query: String, name: String, pattern: String, categoryPath: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let haystacks = [name, pattern, categoryPath]
        let combined = haystacks.joined(separator: " ")
        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        return tokens.allSatisfy { token in
            haystacks.contains { wildcardMatch(pattern: token, text: $0) }
                || wildcardMatch(pattern: token, text: combined)
        }
    }

    /// Returns true if `pattern` (with `*` and `?` wildcards) matches any substring of `text` (case-insensitive).
    static func wildcardMatch(pattern: String, text: String) -> Bool {
        let p = pattern.lowercased()
        let t = text.lowercased()
        if p.isEmpty { return true }
        if !p.contains("*") && !p.contains("?") {
            return t.contains(p)
        }
        var regex = ""
        for ch in p {
            switch ch {
            case "*": regex += ".*"
            case "?": regex += "."
            default: regex += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        return t.range(of: regex, options: .regularExpression) != nil
    }

    /// Computes the reordered array when moving `ruleID` to a new index (#434).
    static func move(rules: [Rule], id: Int64, to destinationIndex: Int) -> [Rule] {
        guard let from = rules.firstIndex(where: { $0.id == id }) else { return rules }
        var copy = rules
        let item = copy.remove(at: from)
        let clamped = max(0, min(destinationIndex, copy.count))
        copy.insert(item, at: clamped)
        return copy
    }
}

/// Keyword / regex auto-categorisation rules with live preview.
struct RuleEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let initialDraft: Rule?

    @State private var selection: Int64?
    @State private var draft: Rule?
    @State private var searchText: String = ""
    @State private var ruleToDelete: Rule?

    private var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredRules: [Rule] {
        guard isFiltering else { return model.rules }
        return model.rules.filter { rule in
            RuleSearchMatcher.matches(
                query: searchText,
                name: rule.name,
                pattern: rule.pattern,
                categoryPath: categoryName(rule.categoryId)
            )
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Regeln filtern (z. B. deu*b) …", text: $searchText)
                        .textFieldStyle(.plain)
                        .appFont(.callout)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Filter zurücksetzen"))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                Divider()

                List(selection: $selection) {
                    ForEach(Array(filteredRules.enumerated()), id: \.element.id) { idx, rule in
                        let rank = (model.rules.firstIndex(where: { $0.id == rule.id }) ?? idx) + 1
                        HStack(spacing: 8) {
                            Text("\(rank).")
                                .appFont(.caption, monospacedDigit: true)
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 22, alignment: .trailing)
                            Image(systemName: rule.enabled ? "wand.and.stars" : "pause.circle")
                                .foregroundStyle(rule.enabled ? Color.readable(hex: color(of: rule)) : .secondary)
                                .accessibilityLabel(Text("Pausiert"))
                                .accessibilityHidden(rule.enabled)
                            VStack(alignment: .leading, spacing: 1) {
                                // rule names are mostly payees ("Miete Müller")
                                Text(rule.name).lineLimit(2).sensitive()
                                Text("→ " + categoryName(rule.categoryId)).appFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    .sensitive(.labels)
                            }
                            Spacer()
                            Text("\(rule.matchCount)")
                                .appFont(.caption, monospacedDigit: true)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(.quaternary))
                                .accessibilityLabel(Text("\(Int(rule.matchCount)) Treffer"))
                        }
                        .tag(rule.id)
                        .contextMenu {
                            let fullIndex = model.rules.firstIndex(where: { $0.id == rule.id }) ?? 0
                            Button {
                                moveRule(id: rule.id, to: 0)
                            } label: {
                                Label("An den Anfang", systemImage: "arrow.up.to.line")
                            }
                            .disabled(fullIndex == 0)

                            Button {
                                moveRule(id: rule.id, to: fullIndex - 1)
                            } label: {
                                Label("Nach oben", systemImage: "arrow.up")
                            }
                            .disabled(fullIndex == 0)

                            Button {
                                moveRule(id: rule.id, to: fullIndex + 1)
                            } label: {
                                Label("Nach unten", systemImage: "arrow.down")
                            }
                            .disabled(fullIndex >= model.rules.count - 1)

                            Button {
                                moveRule(id: rule.id, to: model.rules.count - 1)
                            } label: {
                                Label("Ans Ende", systemImage: "arrow.down.to.line")
                            }
                            .disabled(fullIndex >= model.rules.count - 1)

                            Divider()
                            Button(role: .destructive) {
                                ruleToDelete = rule
                            } label: {
                                Label("Regel löschen …", systemImage: "trash")
                            }
                        }
                    }
                    .onMove(perform: isFiltering ? nil : moveRulesFromList)
                }
            }
            .navigationTitle("Regeln")
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            .toolbar {
                ToolbarItem {
                    Button { newRule() } label: { Label("Neue Regel", systemImage: "plus") }
                }
            }
        } detail: {
            if let current = draft {
                RuleForm(rule: Binding(get: { draft ?? current }, set: { draft = $0 }),
                         onSave: save, onDelete: { ruleToDelete = $0 })
            } else {
                ContentUnavailableView("Keine Regel ausgewählt", systemImage: "wand.and.stars", description: Text("Regeln werden von oben nach unten ausgewertet – die erste passende Regel gewinnt. Reihenfolge per Drag & Drop in der Liste ändern."))
            }
        }
        .macFrame(minWidth: 860, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Fertig") { dismiss() }
            }
            ToolbarItem(placement: .automatic) {
                Button { model.applyAllRules() } label: { Label("Alle Regeln anwenden", systemImage: "play.fill") }
            }
        }
        .confirmationDialog("Regel löschen?",
                            isPresented: Binding(get: { ruleToDelete != nil }, set: { if !$0 { ruleToDelete = nil } }),
                            titleVisibility: .visible, presenting: ruleToDelete) { rule in
            Button("Löschen", role: .destructive) { delete(rule) }
            Button("Abbrechen", role: .cancel) {}
        } message: { _ in
            Text("Buchungen, die diese Regel kategorisiert hat, sind danach wieder ohne Kategorie. Das lässt sich nicht widerrufen.")
        }
        .onAppear {
            if let d = initialDraft {
                draft = d
                selection = d.id == 0 ? nil : d.id
            }
            model.ruleDraft = nil
        }
        .onChange(of: selection) { _, new in
            if let new, let r = model.rules.first(where: { $0.id == new }) { draft = r }
        }
    }

    private func moveRulesFromList(from source: IndexSet, to destination: Int) {
        var reordered = model.rules
        reordered.move(fromOffsets: source, toOffset: destination)
        model.reorderRules(reordered)
        if let sel = selection, let updated = model.rules.first(where: { $0.id == sel }) {
            draft = updated
        }
    }

    private func moveRule(id: Int64, to destinationIndex: Int) {
        let reordered = RuleSearchMatcher.move(rules: model.rules, id: id, to: destinationIndex)
        model.reorderRules(reordered)
        if let sel = selection, let updated = model.rules.first(where: { $0.id == sel }) {
            draft = updated
        }
    }

    private func color(of rule: Rule) -> String {
        model.categories.first { $0.id == rule.categoryId }?.colorHex ?? "#8E8E93"
    }

    private func categoryName(_ id: Int64) -> String {
        model.categories.first { $0.id == id }?.path ?? "?"
    }

    private func newRule() {
        selection = nil
        draft = model.newRuleDraft()
    }

    private func save(_ rule: Rule) {
        if let id = model.saveRule(rule) {
            selection = id
            draft = model.rules.first { $0.id == id }
        }
    }

    private func delete(_ rule: Rule) {
        model.deleteRule(rule.id)
        selection = nil
        draft = nil
    }
}

struct RuleForm: View {
    @Environment(AppModel.self) private var model
    @Binding var rule: Rule
    let onSave: (Rule) -> Void
    let onDelete: (Rule) -> Void

    @State private var minText = ""
    @State private var maxText = ""
    @State private var direction = 0

    var body: some View {
        let preview = model.preview(rule)
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $rule.name)
                    Picker("Kategorie", selection: $rule.categoryId) {
                        ForEach(model.categories) { c in
                            Text(String(repeating: "    ", count: Int(c.depth)) + c.name).tag(c.id)
                        }
                    }
                    .sensitive(.labels)
                    Toggle("Aktiv", isOn: $rule.enabled)
                } header: { Text("Regel").appSectionHeader() }
                Section {
                    if rule.matchKind != .expression {
                        Picker("Suchen in", selection: $rule.field) {
                            Text("Name, Verwendungszweck und Buchungstext").tag(RuleField.any)
                            Text("Name").tag(RuleField.counterparty)
                            Text("Verwendungszweck").tag(RuleField.purpose)
                            Text("Buchungstext").tag(RuleField.bookingText)
                            Text("IBAN").tag(RuleField.counterpartyIban)
                        }
                    }
                    Picker("Art", selection: $rule.matchKind) {
                        Text("Stichwörter").tag(MatchKind.keyword)
                        Text("Regulärer Ausdruck").tag(MatchKind.regex)
                        Text("Suchausdruck").tag(MatchKind.expression)
                    }
                    .pickerStyle(.segmented)
                    if rule.matchKind != .expression {
                        Toggle("Groß-/Kleinschreibung beachten", isOn: $rule.caseSensitive)
                    }
                } header: { Text("Treffer").appSectionHeader() }
                Section {
                    TextField("Muster", text: $rule.pattern, prompt: Text(placeholder), axis: .vertical)
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3...10)
                        .appFont(.body, design: .monospaced)
                        .autocorrectionDisabled()
                        .frame(maxWidth: .infinity, alignment: .leading)
                } header: {
                    Text("Muster").appSectionHeader()
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Beispiel: \(placeholder)")
                            .appFont(.caption, design: .monospaced)
                            .textSelection(.enabled)
                        if rule.matchKind == .expression {
                            Text("Mit AND, OR, NOT, Klammern, „Wortgruppen“, * und ?, /Regex/, Feldern wie name: oder purpose: und Beträgen wie amount<0.")
                        } else if rule.matchKind == .keyword {
                            #if os(macOS)
                            Text("Stichwörter mit | trennen oder eines pro Zeile (neue Zeile mit ⌥↩).")
                            #else
                            Text("Stichwörter mit | trennen oder eines pro Zeile.")
                            #endif
                        }
                    }
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .leadingFooter()
                }
                Section {
                    Picker("Richtung", selection: $direction) {
                        Text("Alle").tag(0)
                        Text("Nur Ausgaben").tag(1)
                        Text("Nur Einnahmen").tag(2)
                    }
                    .pickerStyle(.segmented)
                    RuleAccountPicker(accountIds: $rule.accountIds)
                } header: { Text("Betrag").appSectionHeader() }
                Section {
                    if let err = preview.error {
                        Label(err, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else {
                        Text("\(preview.matches.count >= 200 ? "200+" : String(preview.matches.count)) passende Buchungen")
                            .appFont(.headline)
                        ForEach(preview.matches.prefix(40)) { b in
                            HStack {
                                Text(DateText.medium(b.bookingDate)).foregroundStyle(.secondary).monospacedDigit()
                                Text(b.counterparty).lineLimit(1).sensitive()
                                Spacer()
                                if b.categorySource == .manual {
                                    Image(systemName: "hand.raised.fill").foregroundStyle(.secondary).help("Manuell zugeordnet – die Regel ändert das nicht")
                                }
                                Text(Money.format(b.amountCents)).monospacedDigit().foregroundStyle(Money.ink(b.amountCents))
                                    .sensitive(.amounts)
                            }
                            .appFont(.callout)
                        }
                    }
                } header: {
                    Text("Live-Vorschau").appSectionHeader()
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if rule.id != 0 {
                    Button("Regel löschen …", role: .destructive) { onDelete(rule) }
                }
                Spacer()
                Button("Speichern & anwenden") { onSave(rule) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(rule.pattern.trimmingCharacters(in: .whitespaces).isEmpty || preview.error != nil)
            }
            .padding(12)
        }
        .onAppear(perform: syncDirection)
        .onChange(of: rule.id) { _, _ in syncDirection() }
        .onChange(of: direction) { _, d in
            switch d {
            case 1: rule.minAmountCents = nil; rule.maxAmountCents = 0
            case 2: rule.minAmountCents = 1; rule.maxAmountCents = nil
            default: rule.minAmountCents = nil; rule.maxAmountCents = nil
            }
        }
    }

    private var placeholder: String {
        switch rule.matchKind {
        case .keyword: "REWE | EDEKA | ALDI"
        case .regex: #"^DB\s+(Fernverkehr|Vertrieb)"#
        case .expression: #"name:REWE OR purpose:"Bahn AG""#
        }
    }

    private func syncDirection() {
        if rule.maxAmountCents == 0 { direction = 1 } else if rule.minAmountCents == 1 { direction = 2 } else { direction = 0 }
    }
}
