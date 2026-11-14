import SwiftUI
import GiroCrabCore

// Sachwerte / tangible assets (GitHub #87): a depot without a bank connection
// for gold coins and bars (priced automatically from the daily gold price) and
// things valued by hand (house, car, art). The core keeps dated quantities and
// values, so the value chart stays right after a partial sale.

/// Sachwerte data the views read; refreshed with the accounts.
@Observable final class AssetStore {
    var accountIDs: Set<Int64> = []
    var items: [Int64: [AssetItem]] = [:]
    /// The item sheet on screen.
    var editor: AssetEditorRequest?
    /// "Bewertungen bearbeiten …" / "Anzahl bearbeiten …" / "Sachwert verkaufen …" on screen.
    var action: AssetActionRequest?
    var refreshing = false
    /// The item whose own value chart the header shows.
    var selected: Int64?
    var selectedHistory: [DailyBalance] = []
}

struct AssetActionRequest: Identifiable {
    /// values / quantities = the dated values (manual items) / quantities
    enum Kind { case values, quantities, sell }
    let id = UUID()
    let itemId: Int64
    let kind: Kind
}

struct AssetEditorRequest: Identifiable {
    let id = UUID()
    let accountId: Int64
    /// `nil` = new item.
    var itemId: Int64?
}

// MARK: - Number input

enum NumberText {
    /// One troy ounce in grams (the unit of every metal price).
    static let troyOunceGrams = 31.1034768

    /// "2,5" / "2.5" -> 2.5. With both separators the last one is the decimal
    /// separator ("1.000,5" / "1,000.5"); nil for anything else.
    static func double(_ input: String) -> Double? {
        var t = input.filter { !$0.isWhitespace && $0 != "'" }
        if let c = t.lastIndex(of: ","), let d = t.lastIndex(of: ".") {
            let grouping: Character = c > d ? "." : ","
            t.removeAll { $0 == grouping }
        }
        t = t.replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty, t.filter({ $0 == "." }).count <= 1, let v = Double(t), v.isFinite else { return nil }
        return v
    }

    /// 2.5 -> "2,5" in the user's locale (up to `digits` decimals, never grouped,
    /// so it reads back with `double`).
    static func format(_ value: Double, digits: Int = 4) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0...digits)))
    }
}

// MARK: - Sheets

extension View {
    /// The Sachwerte item sheet, driven by `model.assetStore.editor`.
    func tangibleAssetSheets(_ model: AppModel) -> some View {
        modifier(TangibleAssetSheets(model: model))
    }
}

private struct TangibleAssetSheets: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        @Bindable var store = model.assetStore
        content
            .sheet(item: $store.editor) { req in
                AssetEditorSheet(request: req).environment(model)
            }
            .sheet(item: $store.action) { req in
                Group {
                    if let item = model.assetItem(req.itemId) {
                        switch req.kind {
                        case .values: AssetValuesSheet(item: item)
                        case .quantities: AssetQuantitiesSheet(item: item)
                        case .sell: AssetSellSheet(item: item)
                        }
                    }
                }
                .environment(model)
            }
            .task {
                // screenshots: --demo-sheet asset (new item) | asset-edit | asset-values | asset-quantities (the car)
                guard let sheet = model.options.demoSheet, sheet.hasPrefix("asset"),
                      let account = model.assetStore.accountIDs.first else { return }
                try? await Task.sleep(for: .milliseconds(300))
                let car = model.assetItems(account).first { $0.setup.symbol == "car.side.fill" }
                if sheet == "asset-values" || sheet == "asset-quantities", let car {
                    model.openAssetAction(sheet == "asset-values" ? .values : .quantities, itemId: car.id)
                } else {
                    model.openAssetEditor(accountId: account, itemId: sheet == "asset-edit" ? car?.id : nil)
                }
            }
    }
}

/// "Eigene Angaben" in the denomination picker.
private let customDenomination = -1.0
/// Whether the purchase price field holds the total or the price of one piece.
private enum PriceMode: Hashable { case total, piece }
private enum WeightUnit: String, CaseIterable, Identifiable {
    case gram = "g", kilogram = "kg", ounce = "oz"
    var id: String { rawValue }
    var grams: Double {
        switch self {
        case .gram: 1
        case .kilogram: 1000
        case .ounce: NumberText.troyOunceGrams
        }
    }
}

/// Create / edit a Sachwert. Quantity changes, value points and a missing
/// price are saved right away (edit mode only).
struct AssetEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: AssetEditorRequest

    @State private var name = ""
    /// "XAU" (gold) or "manual".
    @State private var source = "manual"
    /// Grams of a denomination, or `customDenomination`.
    @State private var denomination = NumberText.troyOunceGrams
    @State private var weightText = ""
    @State private var unit = WeightUnit.gram
    @State private var purityText = ""
    @State private var interpolation = AssetInterpolation.step
    @State private var purchaseDate = Date()
    @State private var quantityText = "1"
    @State private var priceText = ""
    @State private var priceMode = PriceMode.total
    /// The text the price field was prefilled with (gold value on the purchase
    /// date); while unchanged it follows date, weight and quantity and is saved
    /// as "no purchase price".
    @State private var autoPriceText: String?
    @State private var note = ""
    /// Chosen icon; new items start with the diamond, "" (older items) = the default for the type.
    @State private var symbol = AssetSymbols.newItemDefault
    @State private var showSymbols = false
    @State private var saveError: String?
    @State private var touched = false
    @State private var loaded = false
    // immediate edits (edit mode)
    @State private var missingPriceText = ""

    private static let weights = assetWeightPresets()
    private var weights: [AssetWeightPreset] { Self.weights }
    private var existing: AssetItem? { request.itemId.flatMap(model.assetItem) }

    // MARK: validation

    private var automatic: Bool { source != "manual" }
    private var priceIsAuto: Bool { autoPriceText != nil && priceText == autoPriceText }
    private var quantity: Double? { NumberText.double(quantityText).flatMap { $0 > 0 ? $0 : nil } }
    /// Total paid (the core stores the total); `.some(nil)` = none given.
    private var purchasePrice: Int64?? {
        let t = priceText.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || priceIsAuto { return .some(nil) }
        guard let c = Money.parseCents(t), c >= 0 else { return nil }
        if priceMode == .total { return .some(c) }
        return .some(Int64((Double(c) * (quantity ?? 1)).rounded()))
    }
    /// The entered price converted to the other mode; nil while nothing to show (no price, quantity 1).
    private var otherPrice: Int64? {
        guard let c = Money.parseCents(priceText.trimmingCharacters(in: .whitespaces)), c >= 0,
              let q = quantity, q != 1 else { return nil }
        return Int64((priceMode == .total ? Double(c) / q : Double(c) * q).rounded())
    }
    private var pricePerPiece: Int64? {
        guard case let .some(.some(total)) = purchasePrice, let q = quantity else { return nil }
        return Int64((Double(total) / q).rounded())
    }
    /// Manual items: the value on the purchase date is the purchase price per piece.
    private var startValue: Int64? { pricePerPiece }
    /// (gross grams per piece, fineness ‰)
    private var weight: (grams: Double, purity: Double)? {
        if denomination != customDenomination { return (denomination, 999.9) }
        guard let w = NumberText.double(weightText), w > 0 else { return nil }
        let p = purityText.trimmingCharacters(in: .whitespaces).isEmpty ? 1000 : NumberText.double(purityText)
        guard let p, p > 0, p <= 1000 else { return nil }
        return (w * unit.grams, p)
    }

    private var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Bitte einen Namen angeben.") }
        if quantity == nil { return String(localized: "Die Anzahl muss größer als 0 sein.") }
        if purchasePrice == nil { return String(localized: "Der Kaufpreis ist keine gültige Zahl.") }
        if automatic {
            if weight == nil { return String(localized: "Bitte Gewicht und Feingehalt (bis 1000 ‰) angeben.") }
        } else if startValue == nil {
            return String(localized: "Bitte den Kaufpreis angeben.")
        }
        return nil
    }

    private var setup: AssetItemSetup? {
        guard problem == nil, let quantity, let purchasePrice else { return nil }
        return AssetItemSetup(
            name: name.trimmingCharacters(in: .whitespaces),
            priceSource: source,
            weightGrams: automatic ? weight?.grams ?? 0 : 0,
            purityPermille: automatic ? weight?.purity ?? 1000 : 1000,
            interpolation: interpolation,
            purchaseDate: DateText.iso(purchaseDate),
            quantity: quantity,
            purchasePriceCents: purchasePrice,
            startValueCents: automatic ? nil : startValue,
            note: note,
            symbol: symbol)
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            Text(existing == nil ? "Neuer Sachwert" : "Sachwert bearbeiten")
                .appFont(.headline)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 20)
            form
            Divider()
            HStack {
                statusLine
                Spacer()
                cancelButton
                saveButton
            }
            .padding(16)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 620)
        .onAppear(perform: load)
        .modifier(prefillTriggers)
        .onChange(of: priceMode) { _, new in convertPrice(to: new) }
        #else
        NavigationStack {
            form
                .navigationTitle(existing == nil ? "Neuer Sachwert" : "Sachwert bearbeiten")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { cancelButton }
                    ToolbarItem(placement: .confirmationAction) { saveButton }
                }
                .safeAreaInset(edge: .bottom) { statusLine.padding(.horizontal).padding(.vertical, 8) }
        }
        .onAppear(perform: load)
        .modifier(prefillTriggers)
        .onChange(of: priceMode) { _, new in convertPrice(to: new) }
        #endif
    }

    /// The item's icon; opens the icon choice.
    /// The units of the presets in their order (g, oz, kg).
    private var weightGroups: [String] {
        weights.compactMap { $0.label.split(separator: " ").last.map(String.init) }
            .reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }
    }

    private var symbolButton: some View {
        let shown = symbol.isEmpty ? AssetSymbols.defaultSymbol(source: source) : symbol
        return Button { showSymbols = true } label: {
            AssetSymbolTile(symbol: shown)
        }
        .buttonStyle(.plain)
        .help("Symbol wählen")
        .accessibilityLabel(Text("Symbol: \(AssetSymbols.name(of: shown))"))
        .popover(isPresented: $showSymbols, arrowEdge: .bottom) {
            AssetSymbolPicker(selection: $symbol, current: shown)
        }
    }

    private var form: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    symbolButton
                    TextField("Name", text: $name, prompt: Text(automatic ? "z. B. Goldbarren 100 g" : "z. B. Auto"))
                }
                // more price sources (silver, …) are added here later
                Picker("Typ", selection: $source) {
                    Text("Manuell").tag("manual")
                    Text("Gold").tag("XAU")
                }
            } footer: {
                FormFooter(automatic
                    ? "Der Wert folgt dem täglichen Goldpreis (EUR je Feinunze, Frankfurter API). Abgefragt werden nur Metall und Zeitraum."
                    : "Für Dinge ohne Kurs, z. B. Haus, Auto oder Kunst: Sie tragen den Wert zu Stichtagen selbst ein.")
            }
            // gold: the denomination first, it sets the price below
            if automatic { goldSection }
            // purchase: date, quantity, then the price (total or per piece)
            Section {
                DatePicker("Kaufdatum", selection: purchaseDateBinding, in: ...Date(), displayedComponents: .date)
                TextField("Anzahl", text: $quantityText, prompt: Text("1"))
                LabeledContent {
                    TextField("Kaufpreis", text: $priceText, prompt: automatic ? Text("optional") : Text("z. B. \(Money.plain(25_000_00))"))
                        .labelsHidden()
                } label: {
                    // borderless, so the menu lines up with the row labels above
                    Menu(priceMode == .total ? "Kaufpreis gesamt" : "Kaufpreis je Stück") {
                        Picker("Kaufpreis", selection: $priceMode) {
                            Text("Kaufpreis gesamt").tag(PriceMode.total)
                            Text("Kaufpreis je Stück").tag(PriceMode.piece)
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                // the other way round, read-only: per piece for a total and vice versa
                if let other = otherPrice {
                    LabeledContent(priceMode == .total ? "Kaufpreis je Stück" : "Kaufpreis gesamt", value: Money.format(other))
                        .foregroundStyle(Theme.secondary)
                }
            } footer: {
                if automatic {
                    FormFooter(priceIsAuto
                        ? "Vorbelegt mit dem Goldwert am Kaufdatum. Ohne eigene Angabe gilt dieser Wert."
                        : "Ohne Kaufpreis gilt der Goldwert am Kaufdatum.")
                }
            }
            if !automatic { manualSection }
            Section {
                TextField("Notiz", text: $note, prompt: Text("z. B. Händler, Zertifikat, Aufbewahrung"), axis: .vertical)
                    .lineLimit(1...4)
            }
            // values and quantities have their own sheets ("Bewertungen bearbeiten …", "Anzahl bearbeiten …")
            if let item = existing, let missing = item.missingPriceDate, item.setup.priceSource != "manual" {
                missingPriceSection(missing)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var goldSection: some View {
        Section {
            Picker("Stückelung", selection: $denomination) {
                // g, oz and kg presets, each block set apart by a divider.
                ForEach(weightGroups, id: \.self) { unit in
                    ForEach(weights.filter { $0.label.split(separator: " ").last.map(String.init) == unit }, id: \.label) {
                        Text($0.label).tag($0.grams)
                    }
                    Divider()
                }
                Text("Eigene Angaben (Schmuck o. ä.)").tag(customDenomination)
            }
            if denomination == customDenomination {
                HStack {
                    TextField("Gewicht je Stück", text: $weightText, prompt: Text("z. B. 10"))
                    Picker("Einheit", selection: $unit) {
                        ForEach(WeightUnit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                TextField("Feingehalt in ‰", text: $purityText, prompt: Text("optional, z. B. 999,9 oder 585"))
            }
            if let w = weight {
                let fine = w.grams * w.purity / 1000
                LabeledContent("Feingold je Stück", value: "\(NumberText.format(fine, digits: 3)) g · \(NumberText.format(fine / NumberText.troyOunceGrams, digits: 4)) oz")
                    .foregroundStyle(Theme.secondary)
            }
        } footer: {
            FormFooter(denomination == customDenomination
                ? "Gewicht und Feingehalt, z. B. 585 ‰ für 14 Karat."
                : "Anlagegold (Münzen und Barren) mit 999,9 ‰ Feingehalt.")
        }
    }

    @ViewBuilder
    private var manualSection: some View {
        Section {
            Picker("Zwischen zwei Werten", selection: $interpolation) {
                Text("Wert bleibt bis zum nächsten").tag(AssetInterpolation.step)
                Text("Linear verlaufen").tag(AssetInterpolation.linear)
            }
        } footer: {
            FormFooter("Der Kaufpreis je Stück ist der erste Wert. Spätere Werte, z. B. aus einem Gutachten, tragen Sie über „Bewertungen bearbeiten …“ im Kontextmenü der Position ein.")
        }
    }

    private func missingPriceSection(_ date: String) -> some View {
        Section {
            HStack {
                TextField("Goldpreis je Feinunze", text: $missingPriceText, prompt: Text("z. B. \(Money.plain(350_00))"))
                Button("Speichern") {
                    guard let c = Money.parseCents(missingPriceText), c > 0 else { return }
                    apply { try $0.setAssetPrice(symbol: "XAU", date: date, priceCents: c) }
                    missingPriceText = ""
                }
                .disabled(Money.parseCents(missingPriceText).map { $0 <= 0 } ?? true)
            }
        } header: {
            Label("Kurs am \(DateText.medium(date)) fehlt", systemImage: "exclamationmark.triangle.fill")
        } footer: {
            FormFooter("Für diesen Tag hat die Kurs-API keinen Goldpreis (die Daten reichen etwa bis 2000 zurück). Ihr Wert gilt bis zum ersten verfügbaren Kurs und wird nie überschrieben.")
        }
    }

    /// Immediate change from inside the sheet.
    private func apply(_ action: (Vault) throws -> Void) {
        do {
            try model.changeAssets(action)
            saveError = nil
            // "Sichern" writes the quantity of the purchase date: keep it current
            if let s = existing?.setup {
                quantityText = NumberText.format(s.quantity)
            }
        } catch {
            saveError = describe(error)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let msg = saveError ?? (touched ? problem : nil) {
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .appFont(.callout)
                .foregroundStyle(Theme.warning)
                .lineLimit(2)
        }
    }

    private var cancelButton: some View {
        Button("Abbrechen", role: .cancel) { dismiss() }
        .keyboardShortcut(.cancelAction)
    }

    private var saveButton: some View {
        Button(existing == nil ? "Anlegen" : "Sichern", action: save)
            .keyboardShortcut(.defaultAction)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let s = existing?.setup else { return }
        name = s.name
        source = s.priceSource
        if automatic {
            if s.purityPermille == 999.9, let w = weights.first(where: { abs($0.grams - s.weightGrams) < 0.0005 }) {
                denomination = w.grams
            } else {
                denomination = customDenomination
                weightText = NumberText.format(s.weightGrams, digits: 4)
                unit = .gram
                purityText = s.purityPermille == 1000 ? "" : NumberText.format(s.purityPermille, digits: 3)
            }
        }
        interpolation = s.interpolation
        purchaseDate = DateText.date(s.purchaseDate) ?? Date()
        quantityText = NumberText.format(s.quantity)
        // manual items saved without a price: their start value is the price per piece
        let paid = s.purchasePriceCents
            ?? (s.priceSource == "manual" ? s.startValueCents.map { Int64((Double($0) * s.quantity).rounded()) } : nil)
        priceText = paid.map(Money.plain) ?? ""
        note = s.note
        symbol = s.symbol
    }

    /// Gold: an empty (or still prefilled) price field shows the gold value
    /// on the purchase date – of all pieces or one, as the field label says.
    /// `force` (the user picked another purchase date) replaces an entered
    /// price too: it belonged to the old date.
    private func prefillPrice(force: Bool = false) {
        guard force || priceText.trimmingCharacters(in: .whitespaces).isEmpty || priceIsAuto else { return }
        var text = ""
        if automatic, let w = weight,
           let p = model.assetPrice(symbol: source, on: DateText.iso(purchaseDate)) {
            let piece = Double(p) * w.grams * w.purity / 1000 / NumberText.troyOunceGrams
            let value = priceMode == .total ? piece * (quantity ?? 1) : piece
            text = Money.plain(Int64(value.rounded()))
        }
        priceText = text
        autoPriceText = text.isEmpty ? nil : text
    }

    /// Switching total ⇄ per piece keeps the amount meaning the same.
    /// A gold value still prefilled is left to `prefillPrice`.
    private func convertPrice(to mode: PriceMode) {
        guard !priceIsAuto, let q = quantity, let c = Money.parseCents(priceText.trimmingCharacters(in: .whitespaces)) else { return }
        priceText = Money.plain(Int64((mode == .total ? Double(c) * q : Double(c) / q).rounded()))
    }

    /// Only a date the user picks refreshes a gold price; `load` sets the
    /// stored date without touching the stored price.
    private var purchaseDateBinding: Binding<Date> {
        Binding(get: { purchaseDate }, set: { new in
            let changed = DateText.iso(new) != DateText.iso(purchaseDate)
            purchaseDate = new
            if changed, automatic { prefillPrice(force: true) }
        })
    }

    private var prefillTriggers: PrefillTriggers {
        PrefillTriggers(keys: [source, DateText.iso(purchaseDate), "\(denomination)", weightText, purityText,
                               unit.rawValue, quantityText, priceMode == .total ? "t" : "p", loaded ? "1" : "0"],
                        action: { prefillPrice() })
    }

    private func save() {
        touched = true
        guard let s = setup else { return }
        do {
            try model.changeAssets { _ = try $0.saveAssetItem(accountId: request.accountId, itemId: request.itemId, setup: s) }
            if s.priceSource != "manual" { model.refreshAssetPrices() }
            dismiss()
        } catch {
            saveError = describe(error)
        }
    }
}

/// Runs `action` whenever one of `keys` changes (and on appear).
private struct PrefillTriggers: ViewModifier {
    let keys: [String]
    let action: () -> Void
    func body(content: Content) -> some View {
        content.onChange(of: keys, initial: true) { action() }
    }
}

/// "Neuer Bestand ab …" input row.
private struct BestandRow: View {
    let item: AssetItem
    let onSet: (String, Double) -> Void
    @State private var date = Date()
    @State private var text = ""

    var body: some View {
        HStack {
            DatePicker("Ab", selection: $date, in: (DateText.date(item.setup.purchaseDate) ?? .distantPast)...Date(), displayedComponents: .date)
                .labelsHidden()
            TextField("Neue Anzahl", text: $text, prompt: Text("Neue Anzahl"))
            Button("Eintragen") {
                guard let q = NumberText.double(text), q >= 0 else { return }
                onSet(DateText.iso(date), q)
                text = ""
            }
            .disabled(NumberText.double(text).map { $0 < 0 } ?? true)
        }
    }
}

/// The new-value row of "Bewertungen bearbeiten": a value on a date, typed as total or per piece
/// (like the purchase price), plus the other amount read-only.
private struct ValueEntryRows: View {
    @Environment(AppModel.self) private var model
    let item: AssetItem
    /// (ISO date, value per piece)
    let onSet: (String, Int64) -> Void
    @State private var date = Date()
    @State private var text = ""
    @State private var mode = PriceMode.piece

    private var day: String { DateText.iso(date) }
    private var held: Double { item.heldQuantity(on: day) }
    private var canTotal: Bool { held > 0 }
    private var entered: Int64? { Money.parseCents(text).flatMap { $0 >= 0 ? $0 : nil } }
    private var perPiece: Int64? {
        entered.map { mode == .total && canTotal ? Int64((Double($0) / held).rounded()) : $0 }
    }
    private var other: Int64? {
        guard canTotal, held != 1, let c = entered else { return nil }
        return Int64((mode == .total ? Double(c) / held : Double(c) * held).rounded())
    }

    var body: some View {
        HStack {
            DatePicker("Am", selection: $date, in: item.purchaseDay...Date(), displayedComponents: .date).labelsHidden()
            if canTotal {
                Menu(mode == .total ? "Wert gesamt" : "Wert je Stück") {
                    Picker("Wert", selection: $mode) {
                        Text("Wert gesamt").tag(PriceMode.total)
                        Text("Wert je Stück").tag(PriceMode.piece)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                Text("Wert je Stück")
            }
            TextField("Wert", text: $text, prompt: Text("Wert"))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
            Button("Eintragen") {
                guard let c = perPiece else { return }
                onSet(day, c)
                text = ""
            }
            .disabled(perPiece == nil)
        }
        // prefilled with the value the chosen day has so far
        .onChange(of: day, initial: true) { prefill() }
        // switching keeps the amount meaning the same
        .onChange(of: mode) { _, new in
            guard canTotal, let c = Money.parseCents(text) else { return }
            text = Money.plain(Int64((new == .total ? Double(c) * held : Double(c) / held).rounded()))
        }
        if let other {
            LabeledContent(mode == .total ? "Wert je Stück" : "Wert gesamt", value: Money.format(other))
                .foregroundStyle(Theme.secondary)
        }
    }

    private func prefill() {
        let value = model.assetUnitValue(itemId: item.id, on: day)
        text = value.map { Money.plain(mode == .total && canTotal ? Int64((Double($0) * held).rounded()) : $0) } ?? ""
    }
}

extension AssetItem {
    /// Pieces held on `day` (ISO): the latest quantity point up to it, 0 before
    /// the purchase (like the core's valuation).
    func heldQuantity(on day: String) -> Double {
        quantities.filter { $0.date <= day }.max { $0.date < $1.date }?.quantity ?? 0
    }

    /// The purchase date as a `Date` (date pickers start there), never after today.
    var purchaseDay: Date { min(DateText.date(setup.purchaseDate) ?? .distantPast, Date()) }
}

// MARK: - Quick actions

/// Small sheet frame shared by the value, quantity and sell sheets.
private struct AssetQuickSheet<Fields: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: LocalizedStringKey
    /// nil: changes are saved as they are made; the sheet only closes ("Fertig").
    let saveTitle: LocalizedStringKey?
    let canSave: Bool
    let error: String?
    let save: () -> Bool
    @ViewBuilder let fields: () -> Fields

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            Text(title)
                .appFont(.headline)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 20)
            Form { fields() }.formStyle(.grouped)
            Divider()
            HStack {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .appFont(.callout).foregroundStyle(Theme.warning).lineLimit(2)
                }
                Spacer()
                if let saveTitle {
                    Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(saveTitle) { if save() { dismiss() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                } else {
                    Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 420, idealWidth: 440)
        #else
        NavigationStack {
            Form {
                fields()
                if let error { Text(error).foregroundStyle(Theme.warning) }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let saveTitle {
                    ToolbarItem(placement: .cancellationAction) { Button("Abbrechen", role: .cancel) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saveTitle) { if save() { dismiss() } }.disabled(!canSave)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
                }
            }
        }
        #endif
    }
}

/// "Bewertungen bearbeiten …" (manual items): the dated values with a row for a new one.
/// Every change is saved at once, so the sheet only has "Fertig".
struct AssetValuesSheet: View {
    @Environment(AppModel.self) private var model
    let item: AssetItem
    @State private var error: String?

    var body: some View {
        AssetQuickSheet(title: "Bewertungen bearbeiten", saveTitle: nil, canSave: true, error: error, save: { true }) {
            Section {
                LabeledContent("Sachwert", value: item.setup.name)
            }
            Section {
                ForEach(item.values.reversed(), id: \.date) { p in
                    HStack {
                        Text(DateText.medium(p.date)).monospacedDigit()
                        Spacer()
                        // per piece; with several pieces then what they were worth together
                        Text(Money.format(p.valueCents)).monospacedDigit()
                        let held = item.heldQuantity(on: p.date)
                        if held > 0, held != 1 {
                            Text("gesamt \(Money.format(Int64((Double(p.valueCents) * held).rounded())))")
                                .monospacedDigit().foregroundStyle(Theme.secondary)
                        }
                        if p.date != item.setup.purchaseDate {
                            AssetRemoveButton { change { try $0.deleteAssetValue(itemId: item.id, date: p.date) } }
                        }
                    }
                }
                ValueEntryRows(item: item) { date, cents in
                    change { try $0.setAssetValue(itemId: item.id, date: date, valueCents: cents) }
                }
            } footer: {
                FormFooter(item.setup.interpolation == .linear
                    ? "Zwischen zwei Werten verläuft der Wert linear. Wird sofort gespeichert."
                    : "Der Wert gilt bis zum nächsten eingetragenen Wert. Wird sofort gespeichert.")
            }
        }
    }

    private func change(_ action: (Vault) throws -> Void) {
        do { try model.changeAssets(action); error = nil } catch { self.error = describe(error) }
    }
}

/// "Anzahl bearbeiten …": the dated quantities (partial sale, additional purchase) with a
/// row for a new one; saved at once like the values.
struct AssetQuantitiesSheet: View {
    @Environment(AppModel.self) private var model
    let item: AssetItem
    @State private var error: String?

    var body: some View {
        AssetQuickSheet(title: "Anzahl bearbeiten", saveTitle: nil, canSave: true, error: error, save: { true }) {
            Section {
                LabeledContent("Sachwert", value: item.setup.name)
            }
            Section {
                ForEach(item.quantities.reversed(), id: \.date) { q in
                    HStack {
                        Text(DateText.medium(q.date)).monospacedDigit()
                        Spacer()
                        Text(q.date == item.setup.purchaseDate ? String(localized: "Kauf: \(NumberText.format(q.quantity))") : String(localized: "ab hier: \(NumberText.format(q.quantity))"))
                            .monospacedDigit()
                        if q.date != item.setup.purchaseDate {
                            AssetRemoveButton { change { try $0.deleteAssetQuantity(itemId: item.id, date: q.date) } }
                        }
                    }
                }
                BestandRow(item: item) { date, qty in change { try $0.setAssetQuantity(itemId: item.id, date: date, quantity: qty) } }
            } footer: {
                FormFooter("Teilverkauf oder Zukauf: die neue Gesamtanzahl ab einem Datum. 0 = alles verkauft. Der Verlauf davor bleibt erhalten. Wird sofort gespeichert.")
            }
        }
    }

    private func change(_ action: (Vault) throws -> Void) {
        do { try model.changeAssets(action); error = nil } catch { self.error = describe(error) }
    }
}

private struct AssetRemoveButton: View {
    let action: () -> Void
    var body: some View {
        Button(role: .destructive, action: action) { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
            .help("Entfernen")
            .accessibilityLabel("Entfernen")
    }
}

/// "Sachwert verkaufen …": the quantity drops from the sale date on, so the item leaves
/// the positions (shown under "Ehemalige Positionen") while its value until the sale stays
/// in the chart.
struct AssetSellSheet: View {
    @Environment(AppModel.self) private var model
    let item: AssetItem
    @State private var date = Date()
    @State private var countText = ""
    @State private var priceText = ""
    @State private var error: String?

    private var manual: Bool { item.setup.priceSource == "manual" }
    /// A sale is from the day after the purchase on (the core refuses the purchase date).
    private var firstSaleDay: Date {
        min(Calendar.current.date(byAdding: .day, value: 1, to: item.purchaseDay) ?? Date(), Date())
    }
    /// Pieces held on the chosen day.
    private var held: Double { item.heldQuantity(on: DateText.iso(date)) }
    private var count: Double? { NumberText.double(countText).flatMap { $0 > 0 && $0 <= held + 1e-9 ? $0 : nil } }
    private var price: Int64?? {
        let t = priceText.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .some(nil) }
        return Money.parseCents(t).flatMap { $0 >= 0 ? .some($0) : nil }
    }

    var body: some View {
        AssetQuickSheet(title: "Sachwert verkaufen", saveTitle: "Verkaufen",
                        canSave: count != nil && price != nil, error: error, save: save) {
            Section {
                LabeledContent("Sachwert", value: item.setup.name)
                DatePicker("Verkauft am", selection: $date, in: firstSaleDay...Date(), displayedComponents: .date)
                TextField("Anzahl", text: $countText, prompt: Text(NumberText.format(held)))
                if manual {
                    TextField("Verkaufspreis je Stück", text: $priceText, prompt: Text("optional"))
                }
            } footer: {
                FormFooter(held > 0
                    ? "Bestand an diesem Tag: \(NumberText.format(held)). Verkaufte Sachwerte stehen danach unter „Ehemalige Positionen“; ihr Wert bis zum Verkauf bleibt im Verlauf."
                    : "An diesem Tag ist kein Bestand vorhanden.")
            }
        }
        .onChange(of: DateText.iso(date), initial: true) { prefill() }
    }

    /// All pieces of that day, and (manual items) their value on it.
    private func prefill() {
        countText = held > 0 ? NumberText.format(held) : ""
        guard manual else { return }
        priceText = model.assetUnitValue(itemId: item.id, on: DateText.iso(date)).map(Money.plain) ?? ""
    }

    private func save() -> Bool {
        guard let n = count, case .some(let p) = price else { return false }
        do {
            // one core call, one transaction: price and quantity or nothing
            try model.changeAssets {
                try $0.sellAsset(itemId: item.id, date: DateText.iso(date), count: n, priceCents: manual ? p : nil)
            }
            return true
        } catch {
            self.error = describe(error)
            return false
        }
    }
}

// MARK: - Icons

/// The icons an asset can carry (SF Symbols, like every other icon in the app).
enum AssetSymbols {
    struct Group: Identifiable {
        let title: LocalizedStringKey
        let items: [(symbol: String, name: LocalizedStringKey)]
        var id: String { items.first?.symbol ?? "" }
    }

    static let groups: [Group] = [
        Group(title: "Edelmetalle & Schmuck", items: [
            ("seal.fill", "Münze"), ("rectangle.stack.fill", "Barren"), (gem, "Edelstein"),
            (necklace, "Kette"), ("crown.fill", "Schmuck"), ("watch.analog", "Uhr"),
        ]),
        Group(title: "Immobilien", items: [
            ("house.fill", "Haus"), ("building.2.fill", "Wohnung"), ("building.columns.fill", "Gewerbe"),
            ("tree.fill", "Grundstück"),
        ]),
        Group(title: "Fahrzeuge", items: [
            ("car.side.fill", "Auto"), ("motorcycle", "Motorrad"), ("bicycle", "Fahrrad"),
            ("sailboat.fill", "Boot"), ("airplane", "Flugzeug"),
        ]),
        Group(title: "Anlagen", items: [
            ("chart.line.uptrend.xyaxis", "Wertpapiere"), ("chart.pie.fill", "Beteiligung"),
            ("bitcoinsign.circle.fill", "Krypto"), ("banknote.fill", "Bargeld"), ("briefcase.fill", "Firma"),
        ]),
        Group(title: "Sammeln & Sonstiges", items: [
            ("photo.artframe", "Kunst"), ("guitars.fill", "Instrument"), ("wineglass.fill", "Wein"),
            ("book.closed.fill", "Sammlung"), ("camera.fill", "Kamera"), ("desktopcomputer", "Technik"),
            ("diamond.fill", "Wertgegenstand"), ("shippingbox.fill", "Sonstiges"),
        ]),
    ]

    /// Own drawings for what SF Symbols lacks.
    static let gem = "girocrab.gem"
    static let necklace = "girocrab.necklace"
    /// Preselected for items created from now on.
    static let newItemDefault = "diamond.fill"

    /// Without a chosen icon: gold shows a coin, everything else a box.
    static func defaultSymbol(source: String) -> String {
        source == "manual" ? "shippingbox.fill" : "seal.fill"
    }

    static func symbol(of item: AssetItem) -> String {
        item.setup.symbol.isEmpty ? defaultSymbol(source: item.setup.priceSource) : item.setup.symbol
    }

    static func name(of symbol: String) -> LocalizedStringKey {
        groups.lazy.flatMap(\.items).first { $0.symbol == symbol }?.name ?? "Symbol"
    }
}

/// The 36 pt tile of a position row, also the editor's icon button.
struct AssetSymbolTile: View {
    let symbol: String
    var size: CGFloat = 36

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Theme.accent.opacity(0.12))
            .frame(width: size, height: size)
            .overlay(AssetSymbolImage(symbol: symbol, size: size * 0.42).foregroundStyle(Theme.accent))
    }
}

/// Grid of icons by topic, sized to show every icon without scrolling.
struct AssetSymbolPicker: View {
    @Binding var selection: String
    /// The icon the item shows now (its type default while none is chosen).
    let current: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(AssetSymbols.groups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.title).appFont(.caption, weight: .semibold).foregroundStyle(Theme.secondary)
                    Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                        ForEach(Array(stride(from: 0, to: group.items.count, by: 8)), id: \.self) { start in
                            GridRow {
                                ForEach(group.items[start..<min(start + 8, group.items.count)], id: \.symbol) { item in
                                    tile(symbol: item.symbol, name: item.name, selected: current == item.symbol) { selection = item.symbol }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .fixedSize()
    }

    private func tile(symbol: String, name: LocalizedStringKey, selected: Bool, pick: @escaping () -> Void) -> some View {
        Button {
            pick()
            dismiss()
        } label: {
            AssetSymbolImage(symbol: symbol, size: 18)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.accent.opacity(0.18) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Theme.accent : Theme.tertiary.opacity(0.3)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Theme.accent : Theme.secondary)
        .help(Text(name))
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// An asset icon: an SF Symbol, or one of the own drawings (gem, necklace).
struct AssetSymbolImage: View {
    let symbol: String
    /// Point size, like the font size of an SF Symbol.
    let size: CGFloat

    var body: some View {
        switch symbol {
        case AssetSymbols.gem: GemGlyph(size: size)
        case AssetSymbols.necklace: NecklaceGlyph(size: size)
        default: Image(systemName: symbol).font(.system(size: size, weight: .semibold))
        }
    }
}

/// A brilliant-cut stone: table on top, girdle, pavilion down to the culet.
private struct GemGlyph: View {
    let size: CGFloat

    var body: some View {
        let w = size * 1.15
        let line = StrokeStyle(lineWidth: max(1.2, size * 0.11), lineCap: .round, lineJoin: .round)
        ZStack {
            Outline().fill(.foreground.opacity(0.3))
            Outline().stroke(.foreground, style: line)
            Facets().stroke(.foreground, style: StrokeStyle(lineWidth: max(1, size * 0.075), lineCap: .round, lineJoin: .round))
        }
        .frame(width: w, height: w * 0.86)
    }

    private struct Outline: Shape {
        func path(in r: CGRect) -> Path {
            Path { p in
                p.move(to: pt(r, 0.27, 0.06)); p.addLine(to: pt(r, 0.73, 0.06))
                p.addLine(to: pt(r, 0.97, 0.36)); p.addLine(to: pt(r, 0.5, 0.96))
                p.addLine(to: pt(r, 0.03, 0.36)); p.closeSubpath()
            }
        }
    }

    private struct Facets: Shape {
        func path(in r: CGRect) -> Path {
            Path { p in
                p.move(to: pt(r, 0.03, 0.36)); p.addLine(to: pt(r, 0.97, 0.36))
                p.move(to: pt(r, 0.27, 0.06)); p.addLine(to: pt(r, 0.34, 0.36)); p.addLine(to: pt(r, 0.5, 0.06))
                p.addLine(to: pt(r, 0.66, 0.36)); p.addLine(to: pt(r, 0.73, 0.06))
                p.move(to: pt(r, 0.34, 0.36)); p.addLine(to: pt(r, 0.5, 0.96)); p.addLine(to: pt(r, 0.66, 0.36))
            }
        }
    }
}

/// A pearl chain hanging in a U with a drop pendant.
private struct NecklaceGlyph: View {
    let size: CGFloat

    var body: some View {
        let w = size * 1.15
        let bead = max(2, size * 0.17)
        ZStack {
            Chain().stroke(.foreground, style: StrokeStyle(lineWidth: bead, lineCap: .round, dash: [0, bead * 1.55]))
            Pendant().fill(.foreground)
        }
        .frame(width: w, height: w)
    }

    private struct Chain: Shape {
        func path(in r: CGRect) -> Path {
            Path { p in
                p.move(to: pt(r, 0.1, 0.08))
                p.addCurve(to: pt(r, 0.5, 0.6), control1: pt(r, 0.1, 0.45), control2: pt(r, 0.3, 0.6))
                p.addCurve(to: pt(r, 0.9, 0.08), control1: pt(r, 0.7, 0.6), control2: pt(r, 0.9, 0.45))
            }
        }
    }

    private struct Pendant: Shape {
        func path(in r: CGRect) -> Path {
            Path { p in
                p.move(to: pt(r, 0.5, 0.62))
                p.addLine(to: pt(r, 0.63, 0.78)); p.addLine(to: pt(r, 0.5, 0.97))
                p.addLine(to: pt(r, 0.37, 0.78)); p.closeSubpath()
            }
        }
    }
}

private func pt(_ r: CGRect, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y)
}
