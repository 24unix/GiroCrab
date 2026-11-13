import SwiftUI
import GiroCrabCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A curated, themed list of SF Symbols for accounts, groups and categories
/// (#167). Modelled on the symbol picker of Reminders/Calendar: sections by
/// topic plus a search over names and symbol names.
enum SymbolCatalog {
    struct Item: Hashable {
        let symbol: String
        let name: LocalizedStringResource

        static func == (a: Item, b: Item) -> Bool { a.symbol == b.symbol }
        func hash(into h: inout Hasher) { h.combine(symbol) }
    }

    struct Section: Identifiable {
        let title: LocalizedStringResource
        let items: [Item]
        var id: String { String(localized: title) }
    }

    private static func i(_ symbol: String, _ name: LocalizedStringResource) -> Item {
        Item(symbol: symbol, name: name)
    }

    /// Every section, with symbols this OS version doesn't know filtered out.
    static let sections: [Section] = raw.map { s in
        Section(title: s.title, items: s.items.filter { systemHas($0.symbol) })
    }.filter { !$0.items.isEmpty }

    private static let raw: [Section] = [
        Section(title: "Finanzen", items: [
            i("banknote", "Geld"), i("creditcard", "Karte"), i("eurosign.circle", "Euro"),
            i("dollarsign.circle", "Dollar"), i("building.columns", "Bank"), i("wallet.bifold", "Geldbörse"),
            i("chart.pie", "Vermögen"), i("chart.line.uptrend.xyaxis", "Rendite"), i("percent", "Zinsen"),
            i("bitcoinsign.circle", "Krypto"), i("giftcard", "Gutschein"), i("arrow.left.arrow.right", "Umbuchung"),
            i("lock.shield", "Sicherheit"), i("doc.text", "Vertrag"), i("building.2", "Firma"),
        ]),
        Section(title: "Haushalt", items: [
            i("house", "Haus"), i("key", "Miete"), i("cart", "Einkauf"), i("basket", "Korb"),
            i("fork.knife", "Essen"), i("cup.and.saucer", "Café"), i("lightbulb", "Strom"), i("flame", "Heizung"),
            i("drop", "Wasser"), i("wifi", "Internet"), i("phone", "Telefon"), i("tv", "Fernsehen"),
            i("sofa", "Möbel"), i("washer", "Waschmaschine"), i("wrench.and.screwdriver", "Reparatur"),
            i("leaf", "Garten"), i("trash", "Müll"),
        ]),
        Section(title: "Mobilität", items: [
            i("car", "Auto"), i("fuelpump", "Tanken"), i("bolt.car", "Elektroauto"), i("bus", "Bus"),
            i("tram", "Straßenbahn"), i("train.side.front.car", "Zug"), i("bicycle", "Fahrrad"),
            i("scooter", "Roller"), i("airplane", "Reisen"), i("ferry", "Fähre"),
            i("parkingsign.circle", "Parken"), i("figure.walk", "Zu Fuß"),
        ]),
        Section(title: "Freizeit", items: [
            i("gamecontroller", "Spiele"), i("film", "Kino"), i("music.note", "Musik"), i("book", "Bücher"),
            i("theatermasks", "Theater"), i("sportscourt", "Sport"), i("figure.run", "Laufen"),
            i("dumbbell", "Fitness"), i("tent", "Camping"), i("beach.umbrella", "Urlaub"),
            i("camera", "Fotografie"), i("paintpalette", "Kunst"), i("ticket", "Tickets"),
            i("party.popper", "Feier"),
        ]),
        Section(title: "Familie", items: [
            i("person", "Person"), i("person.2", "Paar"), i("person.3", "Gruppe"),
            i("figure.and.child.holdinghands", "Familie"), i("figure.2.and.child.holdinghands", "Kinder"),
            i("stroller", "Baby"), i("heart", "Herz"), i("gift", "Geschenk"), i("birthday.cake", "Geburtstag"),
            i("teddybear", "Spielzeug"), i("graduationcap", "Ausbildung"), i("backpack", "Schule"),
            i("pawprint", "Haustier"),
        ]),
        Section(title: "Beruf", items: [
            i("briefcase", "Beruf"), i("laptopcomputer", "Computer"), i("printer", "Drucker"),
            i("folder", "Ordner"), i("tray.full", "Ablage"), i("envelope", "Post"), i("calendar", "Kalender"),
            i("hammer", "Werkzeug"), i("signature", "Unterschrift"), i("chart.bar", "Statistik"),
        ]),
        Section(title: "Gesundheit", items: [
            i("cross.case", "Apotheke"), i("pills", "Medikamente"), i("stethoscope", "Arzt"),
            i("heart.text.square", "Gesundheit"), i("bandage", "Pflaster"), i("eyeglasses", "Brille"),
            i("figure.mind.and.body", "Wellness"), i("bed.double", "Schlaf"), i("scissors", "Friseur"),
            i("shield", "Versicherung"), i("umbrella", "Schutz"),
        ]),
        Section(title: "Sonstiges", items: [
            i("tshirt", "Kleidung"), i("bag", "Einkaufstasche"), i("tag", "Etikett"), i("star", "Favorit"),
            i("flag", "Flagge"), i("globe", "Welt"), i("cloud", "Cloud"), i("sparkles", "Besonderes"),
            i("hand.raised", "Spende"), i("ellipsis.circle", "Andere"), i("questionmark.circle", "Unbekannt"),
        ]),
    ]

    /// Catalogue symbols: known to exist, no image lookup needed (views ask
    /// on every redraw).
    private static let known: Set<String> = Set(sections.flatMap { $0.items.map(\.symbol) })

    /// Whether the running OS ships this SF Symbol.
    static func exists(_ symbol: String) -> Bool {
        guard !symbol.isEmpty else { return false }
        return known.contains(symbol) || systemHas(symbol)
    }

    /// The image lookup itself (also used to build `sections`, so it must not
    /// touch `known`).
    private static func systemHas(_ symbol: String) -> Bool {
        guard !symbol.isEmpty else { return false }
        #if os(macOS)
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
        #else
        return UIImage(systemName: symbol) != nil
        #endif
    }

    /// The catalogue name of a symbol, if it is in the list.
    static func name(of symbol: String) -> LocalizedStringResource? {
        for s in sections { if let item = s.items.first(where: { $0.symbol == symbol }) { return item.name } }
        return nil
    }

    /// Sections matching `query` (name or symbol name, ignoring case and
    /// diacritics). A query that is itself a valid SF Symbol name, but not
    /// in the list, comes first as its own result.
    static func search(_ query: String) -> [Section] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return sections }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var result = sections.compactMap { s -> Section? in
            let hits = s.items.filter {
                String(localized: $0.name).range(of: q, options: opts) != nil
                    || $0.symbol.range(of: q, options: opts) != nil
            }
            return hits.isEmpty ? nil : Section(title: s.title, items: hits)
        }
        let raw = q.lowercased()
        if exists(raw), !result.contains(where: { $0.items.contains { $0.symbol == raw } }) {
            result.insert(Section(title: "SF Symbol", items: [Item(symbol: raw, name: LocalizedStringResource(stringLiteral: raw))]), at: 0)
        }
        return result
    }
}

/// What a "Symbol …" sheet edits.
enum SymbolSheetTarget: Identifiable, Hashable {
    case account(Int64)
    case group(String)
    var id: Self { self }
}

/// The symbol grid with a search field. Picks on click and calls `onPick`
/// (closes the popover or sheet). Always the same size, so it looks the same
/// wherever it is shown.
struct SymbolPicker: View {
    @Binding var selection: String
    var tint: Color = Theme.accent
    var onPick: () -> Void = {}
    @State private var query = ""

    static let size = CGSize(width: 360, height: 420)

    var body: some View {
        let sections = SymbolCatalog.search(query)
        VStack(spacing: 0) {
            SymbolSearchField(text: $query)
                .padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    if sections.isEmpty {
                        Text("Keine Treffer")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else {
                        // not lazy: ~100 small buttons, and every section must
                        // exist so the picker can open at the current symbol
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(sections) { section in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(section.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 6)], spacing: 6) {
                                        ForEach(section.items, id: \.symbol) { item in
                                            cell(item)
                                        }
                                    }
                                }
                                .id(section.id)
                            }
                        }
                        .padding(12)
                    }
                }
                // open at the section of the current symbol
                .onAppear {
                    if let s = sections.first(where: { $0.items.contains { $0.symbol == selection } }) {
                        proxy.scrollTo(s.id, anchor: .top)
                    }
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private func cell(_ item: SymbolCatalog.Item) -> some View {
        let isSelected = item.symbol == selection
        return Button {
            selection = item.symbol
            onPick()
        } label: {
            Image(systemName: item.symbol)
                .font(.title3)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? tint.opacity(0.18) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? tint : Color.clear))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? tint : Theme.secondary)
        .help(Text(item.name))
        .accessibilityLabel(Text(item.name))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The system search field: magnifying glass, leading placeholder, clear
/// button (NSSearchField on macOS).
struct SymbolSearchField: View {
    @Binding var text: String

    var body: some View {
        #if os(macOS)
        NativeSearchField(text: $text, prompt: String(localized: "Symbole durchsuchen"))
            .frame(height: 22)
        #else
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Symbole durchsuchen", text: $text)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Suche löschen"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .tertiarySystemFill)))
        #endif
    }
}

#if os(macOS)
private struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ note: Notification) {
            if let field = note.object as? NSSearchField { text.wrappedValue = field.stringValue }
        }
    }
}
#endif

/// "Symbol …" from a context menu (account or group): the picker in a sheet,
/// since a menu command has no control to anchor a popover to. Picking a
/// symbol applies it and closes the sheet.
struct SymbolSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: SymbolSheetTarget

    private struct Resolved {
        let name: String
        let symbol: String
        let tint: Color
        let set: (String) -> Void
        /// nil = no default to go back to
        let reset: (() -> Void)?
    }

    private var resolved: Resolved? {
        switch target {
        case .account(let id):
            guard let a = model.allAccounts.first(where: { $0.id == id }) else { return nil }
            return Resolved(
                name: a.name, symbol: a.sfSymbol, tint: model.accountColor(id),
                set: { model.setAccountSymbol(id, symbol: $0) },
                // back to the symbol of the account kind (#169)
                reset: { model.resetAccountSymbol(id) }
            )
        case .group(let uuid):
            guard let g = model.userGroups.first(where: { $0.uuid == uuid }) else { return nil }
            return Resolved(
                name: g.name, symbol: g.sfSymbol, tint: Theme.accent,
                set: { model.updateUserGroup(g, symbol: $0) }, reset: nil
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let r = resolved {
                Text("Symbol für „\(r.name)“")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .top], 16)
                    .padding(.bottom, 6)
                SymbolPicker(selection: Binding(get: { r.symbol }, set: r.set), tint: r.tint) { dismiss() }
                Divider()
                HStack {
                    if let reset = r.reset {
                        Button("Standardsymbol") { reset(); dismiss() }
                    }
                    Spacer()
                    Button("Abbrechen", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(16)
            }
        }
        .onDisappear { model.symbolSheet = nil }
    }
}

/// A form row "Symbol [icon]" that opens the picker in a popover anchored to
/// the button – the same picker as the "Symbol …" sheet.
struct SymbolPickerButton: View {
    @Binding var selection: String
    var tint: Color = Theme.accent
    var title: LocalizedStringKey = "Symbol"
    @State private var open = false

    var body: some View {
        LabeledContent(title) {
            Button { open = true } label: {
                // row height like a text field, so the label stays centred
                Image(systemName: SymbolCatalog.exists(selection) ? selection : "questionmark")
                    .font(.body)
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.15)))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Symbol wählen"))
            .accessibilityValue(SymbolCatalog.name(of: selection).map { Text($0) } ?? Text(verbatim: selection))
            .popover(isPresented: $open, arrowEdge: .trailing) {
                SymbolPicker(selection: $selection, tint: tint) { open = false }
                    .presentationCompactAdaptation(.popover)
            }
        }
    }
}
