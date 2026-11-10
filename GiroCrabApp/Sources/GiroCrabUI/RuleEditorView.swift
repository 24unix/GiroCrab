import SwiftUI
import GiroCrabCore

/// Keyword / regex auto-categorisation rules with live preview.
struct RuleEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let initialDraft: Rule?

    @State private var selection: Int64?
    @State private var draft: Rule?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(model.rules) { rule in
                    HStack {
                        Image(systemName: rule.enabled ? "wand.and.stars" : "pause.circle")
                            .foregroundStyle(rule.enabled ? Color.readable(hex: color(of: rule)) : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rule.name).lineLimit(1)
                            Text("→ " + categoryName(rule.categoryId)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text("\(rule.matchCount)")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                    }
                    .tag(rule.id)
                }
            }
            .navigationTitle("Regeln")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .toolbar {
                ToolbarItem {
                    Button { newRule() } label: { Label("Neue Regel", systemImage: "plus") }
                }
            }
        } detail: {
            if let binding = Binding($draft) {
                RuleForm(rule: binding, onSave: save, onDelete: delete)
            } else {
                ContentUnavailableView("Keine Regel ausgewählt", systemImage: "wand.and.stars", description: Text("Regeln ordnen neue Buchungen automatisch Kategorien zu. Die erste passende Regel (nach Priorität) gewinnt; manuelle Zuordnungen werden nie überschrieben."))
            }
        }
        .frame(minWidth: 860, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Fertig") { dismiss() }
            }
            ToolbarItem(placement: .automatic) {
                Button { model.applyAllRules() } label: { Label("Alle Regeln anwenden", systemImage: "play.fill") }
            }
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
    @State private var direction = 0 // 0 any, 1 expenses, 2 income

    var body: some View {
        let preview = model.preview(rule)
        VStack(spacing: 0) {
            Form {
                Section("Regel") {
                    TextField("Name", text: $rule.name)
                    Picker("Kategorie", selection: $rule.categoryId) {
                        ForEach(model.categories) { c in
                            Text(String(repeating: "    ", count: Int(c.depth)) + c.name).tag(c.id)
                        }
                    }
                    Toggle("Aktiv", isOn: $rule.enabled)
                    Stepper("Priorität \(rule.priority)", value: $rule.priority, in: 0...10_000, step: 10)
                }
                Section("Treffer") {
                    Picker("Suchen in", selection: $rule.field) {
                        Text("Name, Verwendungszweck und Buchungstext").tag(RuleField.any)
                        Text("Name").tag(RuleField.counterparty)
                        Text("Verwendungszweck").tag(RuleField.purpose)
                        Text("Buchungstext").tag(RuleField.bookingText)
                        Text("IBAN").tag(RuleField.counterpartyIban)
                    }
                    Picker("Muster", selection: $rule.matchKind) {
                        Text("Stichwörter").tag(MatchKind.keyword)
                        Text("Regulärer Ausdruck").tag(MatchKind.regex)
                    }
                    .pickerStyle(.segmented)
                    TextField(rule.matchKind == .keyword ? "REWE | EDEKA | ALDI" : #"^DB\s+(Fernverkehr|Vertrieb)"#, text: $rule.pattern)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                    Toggle("Groß-/Kleinschreibung beachten", isOn: $rule.caseSensitive)
                }
                Section("Betrag") {
                    Picker("Richtung", selection: $direction) {
                        Text("Alle").tag(0)
                        Text("Nur Ausgaben").tag(1)
                        Text("Nur Einnahmen").tag(2)
                    }
                    .pickerStyle(.segmented)
                    Picker("Konto", selection: $rule.accountId) {
                        Text("Alle Konten").tag(Int64?.none)
                        // Closed accounts only when the rule already uses one.
                        ForEach(model.allAccounts.filter { !$0.closed || $0.id == rule.accountId }) { a in
                            Text("\(a.bankName) – \(a.name)").tag(Int64?.some(a.id))
                        }
                    }
                }
                Section {
                    if let err = preview.error {
                        Label(err, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else {
                        Text("\(preview.matches.count >= 200 ? "200+" : String(preview.matches.count)) passende Buchungen")
                            .font(.headline)
                        ForEach(preview.matches.prefix(40)) { b in
                            HStack {
                                Text(DateText.medium(b.bookingDate)).foregroundStyle(.secondary).monospacedDigit()
                                Text(b.counterparty).lineLimit(1)
                                Spacer()
                                if b.categorySource == .manual {
                                    Image(systemName: "hand.raised.fill").foregroundStyle(.secondary).help("Manuell zugeordnet – die Regel ändert das nicht")
                                }
                                Text(Money.format(b.amountCents)).monospacedDigit().foregroundStyle(Money.ink(b.amountCents))
                            }
                            .font(.callout)
                        }
                    }
                } header: {
                    Text("Live-Vorschau")
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if rule.id != 0 {
                    Button("Regel löschen", role: .destructive) { onDelete(rule) }
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

    private func syncDirection() {
        if rule.maxAmountCents == 0 { direction = 1 } else if rule.minAmountCents == 1 { direction = 2 } else { direction = 0 }
    }
}
