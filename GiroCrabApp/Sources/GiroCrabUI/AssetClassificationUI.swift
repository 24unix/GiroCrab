import SwiftUI
import GiroCrabCore

extension AssetClass {
    static let choices: [Self] = [.equity, .bond, .realEstate, .commodity, .crypto, .cash, .multiAsset, .other, .unclassified]
    /// What a user can pick: "Automatisch" already stands for "no own choice".
    static let assignable = choices.filter { $0 != .unclassified }
    var key: String { switch self {
    case .equity: "equity"; case .bond: "bond"; case .realEstate: "real_estate"
    case .commodity: "commodity"; case .crypto: "crypto"; case .cash: "cash"
    case .multiAsset: "multi_asset"; case .other: "other"; case .unclassified: "unclassified"
    } }
    var title: String { switch self {
    case .equity: String(localized: "Aktien"); case .bond: String(localized: "Anleihen")
    case .realEstate: String(localized: "Immobilien"); case .commodity: String(localized: "Rohstoffe & Edelmetalle")
    case .crypto: String(localized: "Krypto"); case .cash: String(localized: "Liquidität & Geldmarkt")
    case .multiAsset: String(localized: "Mischanlagen / Multi-Asset"); case .other: String(localized: "Sonstiges")
    case .unclassified: String(localized: "Nicht klassifiziert")
    } }
}
extension InstrumentKind {
    static let choices: [Self] = [.singleSecurity, .etf, .fund, .etcEtn, .derivative, .directHolding, .other, .unclassified]
    static let assignable = choices.filter { $0 != .unclassified }
    var key: String { switch self {
    case .singleSecurity: "single"; case .etf: "etf"; case .fund: "fund"; case .etcEtn: "etc_etn"
    case .derivative: "derivative"; case .directHolding: "direct"; case .other: "other"; case .unclassified: "unclassified"
    } }
    var title: String { switch self {
    case .singleSecurity: String(localized: "Einzeltitel"); case .etf: "ETF"; case .fund: String(localized: "Fonds")
    case .etcEtn: "ETC/ETN"; case .derivative: String(localized: "Derivat / strukturiertes Produkt")
    case .directHolding: String(localized: "Direktbesitz"); case .other: String(localized: "Sonstiges")
    case .unclassified: String(localized: "Nicht klassifiziert")
    } }
}
extension ClassificationSource {
    var title: String { switch self {
    case .user: String(localized: "Eigene Zuordnung"); case .import: String(localized: "Importiert")
    case .rule: String(localized: "Automatisch ermittelt"); case .unknown: String(localized: "Nicht klassifiziert")
    } }
}
extension AssetClassification {
    /// Sachwerte carry their own identity; "Direktbesitz" is true for each of them and says nothing.
    var isTangible: Bool { securityKey?.hasPrefix("asset:") == true }
    var instrumentTitle: String? {
        instrument == .unclassified || (isTangible && instrument == .directHolding) ? nil : instrument.title
    }
    var compactTitle: String {
        [assetClass.title, instrumentTitle].compactMap { $0 }.joined(separator: " · ")
    }
    var sourceDescription: String {
        String(localized: "Anlageklasse") + ": " + assetClassSource.title + " · "
            + String(localized: "Instrument") + ": " + instrumentSource.title
    }
}
/// How the wealth view groups its values. A further dimension (owner, depot) is a new case plus
/// its line in `WealthClassRow.group(by:)`; chart, legend filter and cards follow from that.
enum WealthGrouping: String, CaseIterable, Identifiable {
    case account, assetClass, instrument
    var id: String { rawValue }

    /// The wrapper (ETF, single security, fund) only tells securities apart.
    static func available(in scope: WealthScope) -> [Self] {
        scope == .securities ? [.account, .assetClass, .instrument] : [.account, .assetClass]
    }
    /// The stored choice, or the class view where the stored one is not offered.
    func effective(in scope: WealthScope) -> Self {
        Self.available(in: scope).contains(self) ? self : .assetClass
    }
    /// Inside one account type the "account" grouping lists the single positions, so it says so.
    func title(in scope: WealthScope) -> LocalizedStringKey {
        switch self {
        case .account: scope == .securities || scope == .tangibles ? "Nach Position" : "Nach Konto"
        case .assetClass: "Nach Anlageklasse"
        case .instrument: "Nach Instrument"
        }
    }
}

/// Whose accounts the wealth view shows (#280: the owner is editable per account). A filter in
/// front of everything else: totals, charts and positions are built from the accounts it keeps.
enum WealthOwnerFilter: Hashable {
    case all
    case owner(String)
    /// Accounts without an owner, e.g. shared or manually kept ones.
    case unassigned

    func keeps(_ account: Account) -> Bool {
        switch self {
        case .all: true
        case .owner(let name): Self.name(of: account) == name
        case .unassigned: Self.name(of: account).isEmpty
        }
    }
    static func name(of account: Account) -> String {
        account.owner.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// The choices worth offering: nothing while all accounts belong to at most one person.
    static func options(for accounts: [Account]) -> [Self] {
        let names = Set(accounts.map(name(of:)))
        let owners = names.filter { !$0.isEmpty }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        guard owners.count > 1 else { return [] }
        return [.all] + owners.map(Self.owner) + (names.contains("") ? [.unassigned] : [])
    }
}

/// One slice of the grouped wealth view: an asset class or an instrument kind.
struct WealthGroup: Hashable {
    let key: String
    let title: String
    /// Position in the fixed list of its dimension: stable colours and card order.
    let order: Int
    /// "Nicht klassifiziert": grey, hideable in the chart, offers the assign queue.
    let unclassified: Bool
}

/// One or several positions to classify; several are worked through one after the other.
struct ClassificationEditRequest: Identifiable {
    struct Entry {
        let name: String
        let classification: AssetClassification
    }
    let entries: [Entry]
    var id: String { entries.first.map { $0.classification.securityKey ?? $0.name } ?? "" }

    init(name: String, classification: AssetClassification) {
        entries = [Entry(name: name, classification: classification)]
    }
    /// Positions without a stable key cannot be stored; the same security in two depots is one entry.
    init(entries: [Entry]) {
        var seen = Set<String>()
        self.entries = entries.filter { $0.classification.securityKey.map { seen.insert($0).inserted } ?? false }
    }
}
struct AssetClassificationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ClassificationEditRequest
    @State private var index = 0
    @State private var asset = ""
    @State private var instrument = ""
    @State private var busy = false
    @State private var saved = false
    @State private var error: String?
    @State private var pin: VaultPin?
    private var entry: ClassificationEditRequest.Entry { request.entries[min(index, request.entries.count - 1)] }
    private var current: AssetClassification { entry.classification }
    private var hasNext: Bool { index + 1 < request.entries.count }
    // an explicit "unclassified" from an older state reads as automatic: both mean "not assigned"
    private var initialAsset: String { current.assetClassSource == .user && current.assetClass != .unclassified ? current.assetClass.key : "" }
    private var initialInstrument: String { current.instrumentSource == .user && current.instrument != .unclassified ? current.instrument.key : "" }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.name)
                    .sensitive(current.isTangible ? .personal : .labels)
                    .appFont(.headline)
                Spacer()
                if request.entries.count > 1 {
                    Text("Position \(index + 1) von \(request.entries.count)")
                        .appFont(.caption).foregroundStyle(Theme.secondary)
                }
            }
            Form {
                Picker("Anlageklasse", selection: $asset) {
                    Text("Automatisch").tag("")
                    ForEach(AssetClass.assignable, id: \.key) { Text($0.title).tag($0.key) }
                }
                Picker("Instrument", selection: $instrument) {
                    Text("Automatisch").tag("")
                    ForEach(InstrumentKind.assignable, id: \.key) { Text($0.title).tag($0.key) }
                }
                LabeledContent("Aktuelle Anlageklasse", value: Self.state(current.assetClass.title, current.assetClassSource))
                LabeledContent("Aktuelles Instrument", value: Self.state(current.instrument.title, current.instrumentSource))
            }
            // outside the form: a long line inside it widens the form beyond the sheet
            Text(current.isTangible
                 ? String(localized: "Die eigene Zuordnung gilt für diesen Sachwert. Automatisch setzt nur das jeweilige Merkmal zurück.")
                 : String(localized: "Eigene Zuordnungen gelten für dieses Wertpapier in allen Depots dieses Tresors. Automatisch setzt nur das jeweilige Merkmal zurück."))
                .appFont(.caption).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(Theme.negative).appFont(.caption) }
            HStack {
                Button(saved ? "Fertig" : "Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if hasNext {
                    Button("Speichern") { save(advance: false) }.disabled(busy || pin == nil)
                    Button("Speichern & weiter") { save(advance: true) }.buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction).disabled(busy || pin == nil)
                } else {
                    Button("Speichern") { save(advance: false) }.buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction).disabled(busy || pin == nil)
                }
            }
        }
        .padding(20).macFrame(width: 560)
        .interactiveDismissDisabled(busy)
        .onAppear { load(); pin = model.pinVault() }
    }
    /// "Aktien · Importiert"; without a source there is nothing to add to "Nicht klassifiziert".
    private static func state(_ value: String, _ source: ClassificationSource) -> String {
        source == .unknown ? value : value + " · " + source.title
    }
    private func load() { asset = initialAsset; instrument = initialInstrument; error = nil }
    private func save(advance: Bool) {
        guard let pin, let key = current.securityKey else { return }
        let assetChanged = asset != initialAsset, instrumentChanged = instrument != initialInstrument
        let chosenAsset = AssetClass.assignable.first { $0.key == asset }
        let chosenInstrument = InstrumentKind.assignable.first { $0.key == instrument }
        busy = true
        Task {
            do {
                try await pin.run { vault in
                    if assetChanged { try vault.setAssetClassOverride(securityKey: key, value: chosenAsset) }
                    if instrumentChanged { try vault.setInstrumentOverride(securityKey: key, value: chosenInstrument) }
                }
                await pin.checkpoint()
                // only the classification changed: the views that show it reload on this counter
                if model.isCurrent(pin), assetChanged || instrumentChanged { model.assetClassificationVersion += 1 }
                saved = saved || assetChanged || instrumentChanged
                if advance && hasNext { index += 1; load() } else { dismiss() }
            } catch { self.error = describe(error) }
            busy = false
        }
    }
}

/// One view-level selection, shared by totals, charts and both position presentations.
/// Removing a property subtracts its value once; a missing-position remainder stays intact.
struct WealthAssetSelection {
    var summary: WealthSummary
    var assets: [Int64: [ClassifiedAsset]]
    /// Direct property per bucket, counted whether hidden or not (the switch must stay reachable).
    var directProperty: [WealthBucket: Int] = [:]
    var directPropertyCount: Int { directProperty.values.reduce(0, +) }

    static func isDirectProperty(_ asset: ClassifiedAsset) -> Bool {
        asset.classification.assetClass == .realEstate && asset.classification.instrument == .directHolding
    }

    init(summary: WealthSummary, assets: [Int64: [ClassifiedAsset]], hideDirectProperty: Bool) {
        self.summary = summary
        self.assets = assets
        for bucket in WealthBucket.assetBuckets {
            guard !summary.accounts(bucket).isEmpty else { continue }
            self.summary.buckets[bucket] = summary.accounts(bucket).compactMap { account in
                let items = assets[account.id] ?? []
                let properties = items.filter(Self.isDirectProperty)
                directProperty[bucket, default: 0] += properties.count
                guard hideDirectProperty, !properties.isEmpty else { return account }
                let kept = items.filter { !Self.isDirectProperty($0) }
                self.assets[account.id] = kept
                var adjusted = account
                adjusted.balanceCents -= properties.reduce(0) { $0 + $1.holding.valueCents }
                return kept.isEmpty && adjusted.balanceCents == 0 ? nil : adjusted
            }
        }
    }
}

struct WealthClassRow: Identifiable {
    let id: String
    let name: String
    let accountName: String
    let cents: Int64
    let scope: WealthScope
    let classification: AssetClassification
    var quantity: Double? = nil
    var identifier = ""
    /// Under an instrument heading the class is the missing half, and the other way round.
    func subtitle(by grouping: WealthGrouping) -> String {
        guard grouping == .instrument else { return subtitle }
        return subtitle(last: classification.assetClass == .unclassified ? nil : classification.assetClass.title)
    }
    var subtitle: String { subtitle(last: classification.instrumentTitle) }
    private func subtitle(last: String?) -> String {
        // one piece of a Sachwert is the normal case, not information
        let units = quantity.flatMap { $0.isFinite && $0 > 0 && !(classification.isTangible && $0 == 1) ? String(localized: "\(NumberText.format($0)) Stück") : nil }
        return [units, identifier.isEmpty ? nil : identifier, accountName, last]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    func group(by grouping: WealthGrouping) -> WealthGroup {
        if grouping == .instrument {
            let kind = classification.instrument
            return WealthGroup(key: kind.key, title: kind.title, order: InstrumentKind.choices.firstIndex(of: kind) ?? 0, unclassified: kind == .unclassified)
        }
        let asset = classification.assetClass
        return WealthGroup(key: asset.key, title: asset.title, order: AssetClass.choices.firstIndex(of: asset) ?? 0, unclassified: asset == .unclassified)
    }
    static func make(_ s: WealthSummary, assets: [Int64: [ClassifiedAsset]]) -> [Self] {
        func c(_ asset: AssetClass, source: ClassificationSource = .rule) -> AssetClassification {
            AssetClassification(securityKey: nil, assetClass: asset, assetClassSource: source, instrument: .unclassified, instrumentSource: .unknown)
        }
        var rows = s.cash.map { Self(id: "cash:\($0.id)", name: $0.name, accountName: $0.bankName, cents: $0.balanceCents, scope: .cash, classification: c(.cash)) }
        rows += s.liabilities.filter { $0.balanceCents > 0 }.map { Self(id: "credit:\($0.id)", name: $0.name, accountName: $0.bankName, cents: $0.balanceCents, scope: .cash, classification: c(.cash)) }
        for (accounts, scope) in [(s.depots, WealthScope.securities), (s.tangibles, WealthScope.tangibles)] {
            for account in accounts {
                let items = assets[account.id] ?? []
                rows += items.enumerated().map { index, item in
                    Self(id: "asset:\(account.id):\(index)", name: item.holding.name, accountName: account.name, cents: item.holding.valueCents, scope: scope, classification: item.classification,
                         quantity: item.holding.quantity, identifier: item.holding.isin.isEmpty ? item.holding.wkn : item.holding.isin)
                }
                let remainder = account.balanceCents - items.reduce(0) { $0 + $1.holding.valueCents }
                if remainder != 0 {
                    rows.append(Self(id: "rest:\(account.id)", name: String(localized: "Ohne Positionsdaten / Bewertungsdifferenz"), accountName: account.name, cents: remainder, scope: scope, classification: c(.unclassified, source: .unknown)))
                }
            }
        }
        return rows
    }
}
