import SwiftUI
import Charts
import GiroCrabCore

/// Where an account lands in the wealth view. THE single mapping point: later asset
/// classes (precious metals and other tangibles #87, real estate #252, crypto) become
/// new `assetBuckets` cases plus one line in `bucket(for:)`; the view lists every
/// non-empty asset bucket as its own section, no further UI work.
enum WealthBucket: CaseIterable {
    case cash, securities, tangibles, liabilities

    static let assetBuckets: [WealthBucket] = [.securities, .tangibles]

    var title: LocalizedStringKey {
        switch self {
        case .cash: "Cash"
        case .securities: "Wertpapiere"
        case .tangibles: "Sachwerte"
        case .liabilities: "Verbindlichkeiten"
        }
    }

    /// Sachwerte (property, car, gold …) are stored as a depot-like account, but they are no securities.
    static func bucket(for account: Account, tangible: Bool = false) -> WealthBucket {
        switch account.kind {
        case .checking, .savings, .cash, .paymentService: .cash
        case .brokerage: tangible ? .tangibles : .securities
        case .creditCard, .loan: .liabilities
        }
    }
}

/// Net-worth figures derived from the account list (stock, not flow). Only active,
/// EUR accounts that count towards the overall total are included.
struct WealthSummary: Equatable {
    var buckets: [WealthBucket: [Account]] = [:]
    /// Active accounts in another currency: shown as a note, not summed.
    var foreignCurrencyCount = 0

    init() {}

    init(accounts: [Account], tangibleIds: Set<Int64> = []) {
        for a in accounts where a.archivedUnix == nil && a.inTotal {
            guard a.currency == "EUR" else { foreignCurrencyCount += 1; continue }
            buckets[WealthBucket.bucket(for: a, tangible: tangibleIds.contains(a.id)), default: []].append(a)
        }
    }

    func accounts(_ b: WealthBucket) -> [Account] { buckets[b] ?? [] }
    func cents(_ b: WealthBucket) -> Int64 { accounts(b).reduce(0) { $0 + $1.balanceCents } }

    var cash: [Account] { accounts(.cash) }
    var depots: [Account] { accounts(.securities) }
    var tangibles: [Account] { accounts(.tangibles) }
    var liabilities: [Account] { accounts(.liabilities) }
    var cashCents: Int64 { cents(.cash) }
    var assetsCents: Int64 { WealthBucket.assetBuckets.reduce(0) { $0 + cents($1) } }
    /// Debts: the negative balances of cards and loans. They reduce wealth.
    var liabilitiesCents: Int64 { liabilities.reduce(0) { $0 + min($1.balanceCents, 0) } }
    /// A positive card balance (credit) is an asset: it stays when the debts are left out.
    var creditCents: Int64 { liabilities.reduce(0) { $0 + max($1.balanceCents, 0) } }
    /// Cash, assets and card credit: what the "assets" bar and the donut add up to.
    var grossCents: Int64 { cashCents + assetsCents + creditCents }
    var netCents: Int64 { netCents(includingLiabilities: true) }
    func netCents(includingLiabilities: Bool) -> Int64 {
        grossCents + (includingLiabilities ? liabilitiesCents : 0)
    }
    func scoped(to scope: WealthScope) -> Self {
        guard scope != .all else { return self }
        let bucket: WealthBucket = switch scope {
        case .cash: .cash
        case .securities: .securities
        case .tangibles: .tangibles
        case .all: .cash // handled above
        }
        var filtered = Self()
        filtered.buckets[bucket] = accounts(bucket)
        return filtered
    }
}

/// One security summed over all depots.
struct WealthPosition: Identifiable, Equatable {
    let isin: String
    var name: String
    var quantity: Double
    var valueCents: Int64
    /// Change since the previous day / unrealized gain, summed over the depots that report them
    /// (nil when no depot does: not every bank delivers these fields).
    var dayChangeCents: Int64?
    var gainCents: Int64?
    /// Holdings merged into this position and how many of them report each figure; counted
    /// before merging, so a position with one reporting depot out of two is not "complete".
    var lines = 1
    var dayLines = 0
    var gainLines = 0
    var id: String { isin }

    /// Totals over all positions: holdings, with a day change, with a gain.
    static func coverage(_ positions: [WealthPosition]) -> (lines: Int, day: Int, gain: Int) {
        (positions.reduce(0) { $0 + $1.lines }, positions.reduce(0) { $0 + $1.dayLines },
         positions.reduce(0) { $0 + $1.gainLines })
    }

    private static func add(_ a: Int64?, _ b: Int64?) -> Int64? {
        switch (a, b) {
        case let (x?, y?): x + y
        case let (x?, nil): x
        case let (nil, y?): y
        default: nil
        }
    }

    static func aggregate(_ perDepot: [[Holding]]) -> [WealthPosition] {
        var byKey: [String: WealthPosition] = [:]
        for depot in perDepot {
          for h in depot {
            let key = h.isin.isEmpty ? (h.wkn.isEmpty ? h.name : h.wkn) : h.isin
            let day = h.prevDayValueCents.map { h.valueCents - $0 }
            // reported by the bank, else calculated from the cost price like the depot view does
            let gain = h.profitLossPurchaseCents ?? DepotPositionsView.calculatedGain(h)?.cents
            if var p = byKey[key] {
                p.quantity += h.quantity
                p.valueCents += h.valueCents
                p.dayChangeCents = add(p.dayChangeCents, day)
                p.gainCents = add(p.gainCents, gain)
                p.lines += 1
                p.dayLines += day == nil ? 0 : 1
                p.gainLines += gain == nil ? 0 : 1
                byKey[key] = p
            } else {
                byKey[key] = WealthPosition(isin: key, name: h.name.isEmpty ? key : h.name,
                                            quantity: h.quantity, valueCents: h.valueCents,
                                            dayChangeCents: day, gainCents: gain,
                                            lines: 1, dayLines: day == nil ? 0 : 1, gainLines: gain == nil ? 0 : 1)
            }
          }
        }
        return byKey.values.sorted { $0.valueCents != $1.valueCents ? $0.valueCents > $1.valueCents : $0.name < $1.name }
    }
}

/// Distributions and costs of the depots over the last twelve months (EUR only).
struct WealthIncome: Equatable {
    var dividendsCents: Int64 = 0
    var feesCents: Int64 = 0
    var taxesCents: Int64 = 0
    var isEmpty: Bool { dividendsCents == 0 && feesCents == 0 && taxesCents == 0 }

    /// Fees and taxes are positive amounts; separate fee/tax columns of trades count too.
    static func make(_ transactions: [SecurityTransaction], since: String) -> WealthIncome {
        var r = WealthIncome()
        for t in transactions where t.currency == "EUR" && t.bookingDate >= since {
            switch t.direction {
            case .dividend: r.dividendsCents += t.valueCents
            case .fee: r.feesCents += abs(t.valueCents)
            case .tax: r.taxesCents += abs(t.valueCents)
            case .buy, .sell, .other: break
            }
            if t.direction != .fee { r.feesCents += t.feesCents }
            if t.direction != .tax { r.taxesCents += t.taxesCents }
        }
        return r
    }
}

/// Segmented control of the wealth view: stock, not flow.
enum WealthScope: CaseIterable, Identifiable {
    case all, cash, securities, tangibles
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .all: "Alles"
        case .cash: "Cash"
        case .securities: "Wertpapiere"
        case .tangibles: "Sachwerte"
        }
    }
}

/// A slice of the donut: a bucket, an account or a position.
struct WealthSlice: Identifiable, Equatable {
    let id: String
    let label: String
    let cents: Int64
    let color: Color

    /// Charts returns a value on the cumulative positive-value scale, not a sector index.
    static func id(at value: Double, in slices: [Self]) -> String? {
        guard value.isFinite, value >= 0 else { return nil }
        var end = 0.0
        for slice in slices where slice.cents > 0 {
            end += Double(slice.cents)
            if value < end { return slice.id }
        }
        return nil
    }
}

enum WealthPalette {
    /// Distinct, colour-blind friendly hues for donut slices (index wraps).
    static let hues: [Color] = [
        Color(light: "#2F6FDB", dark: "#6EA0F5"), Color(light: "#1F7A5C", dark: "#5EC79F"),
        Color(light: "#D98A00", dark: "#F5B94A"), Color(light: "#8E4FC4", dark: "#B98AE6"),
        Color(light: "#D1495B", dark: "#F27F8E"), Color(light: "#0E8FA8", dark: "#5CC6DB"),
        Color(light: "#7C9A2D", dark: "#A9C95C"), Color(light: "#B0568F", dark: "#DB8FC0"),
    ]
    static func color(_ i: Int) -> Color { hues[i % hues.count] }
    /// The folded remainder ("Sonstige"): neutral, so it never looks like one of the named slices.
    static let rest = Color(light: "#B4BEC8", dark: "#6B7785")
}

/// Toolbar control of the wealth view (replaces the booking scope there).
struct WealthScopePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker("Ansicht", selection: Binding(get: { model.wealthScope }, set: { model.wealthScope = $0 })) {
            ForEach(WealthScope.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// "Vermögen": cash and assets (depots) at a glance, minus liabilities.
struct WealthView: View {
    @Environment(AppModel.self) private var model
    @State private var income = WealthIncome()
    @State private var classified: [Int64: [ClassifiedAsset]] = [:]
    @State private var editingClassification: ClassificationEditRequest?
    /// Yesterday's value of one piece per automatically priced Sachwert (item id): the day change.
    @State private var tangiblePreviousUnit: [Int64: Int64] = [:]
    /// "Nach Konto" keeps the cash history, gains and income cards; the class view is opt-in.
    @AppStorage("wealth.grouping") private var storedGrouping = WealthGrouping.account
    private var grouping: WealthGrouping { storedGrouping.effective(in: scope) }
    /// The selected donut slice: a class or instrument in the grouped view, else a section, account or position.
    @State private var classFilter = "all"
    @AppStorage("wealth.hideUnclassifiedInChart") private var hideUnclassifiedInChart = false
    @AppStorage("wealth.hideDirectProperty") private var hideDirectProperty = false
    private var scope: WealthScope { model.wealthScope }
    /// Grouped by a classification (asset class or instrument) instead of by account.
    private var classMode: Bool { grouping != .account && scope != .cash }
    /// Credit cards and loans reduce the net worth (on by default).
    @AppStorage("wealth.includeLiabilities") private var includeLiabilities = true
    @State private var historyDays = 90
    @State private var history: [DailyBalance] = []

    @State private var ownerFilter = WealthOwnerFilter.all
    /// Every counted account: what is loaded, and what the owner choices are built from.
    private var allSummary: WealthSummary {
        WealthSummary(accounts: model.allAccounts, tangibleIds: Set(model.allAccounts.map(\.id).filter { model.isTangible($0) }))
    }
    private var ownerOptions: [WealthOwnerFilter] {
        WealthOwnerFilter.options(for: WealthBucket.allCases.flatMap { allSummary.accounts($0) })
    }
    /// An owner that no longer exists (renamed, account archived) shows everybody.
    private var activeOwner: WealthOwnerFilter { ownerOptions.contains(ownerFilter) ? ownerFilter : .all }
    /// The accounts of the selected owner; everything below derives from this.
    private var fullSummary: WealthSummary {
        let owner = activeOwner
        let accounts = owner == .all ? model.allAccounts : model.allAccounts.filter(owner.keeps)
        return WealthSummary(accounts: accounts, tangibleIds: Set(accounts.map(\.id).filter { model.isTangible($0) }))
    }
    /// Everything the cards derive from accounts and positions, built once per render.
    private struct Derived {
        let selection: WealthAssetSelection
        /// Limited to the selected tab.
        let summary: WealthSummary
        let positions: [WealthPosition]
        /// Class view only: the rows of the selected tab, before the class filter.
        let classRows: [WealthClassRow]
    }
    private var derived: Derived {
        let selection = WealthAssetSelection(summary: fullSummary, assets: classified, hideDirectProperty: hideDirectProperty)
        let rows = classMode
            ? WealthClassRow.make(selection.summary, assets: selection.assets).filter { scope == .all || $0.scope == scope }
            : []
        return Derived(selection: selection, summary: selection.summary.scoped(to: scope),
                       positions: WealthPosition.aggregate(selection.summary.depots.map { (selection.assets[$0.id] ?? []).map(\.holding) }),
                       classRows: rows)
    }
    /// The selected donut slice of the account view, applied to the lists below it.
    struct SliceFilter {
        /// nil: nothing selected, or the selected slice is gone.
        var id: String?
        /// Slices shown by name; "Sonstige" stands for everything else.
        var named: Set<String> = []
        var isActive: Bool { id != nil }
        func keeps(_ candidate: String) -> Bool {
            guard let id else { return true }
            return id == "rest" ? !named.contains(candidate) : id == candidate
        }
        init(selected: String, slices: [WealthSlice]) {
            guard slices.contains(where: { $0.id == selected }) else { return }
            id = selected
            named = Set(slices.map(\.id)).subtracting(["rest"])
        }
    }

    /// A filter whose class no longer exists (last position reassigned) shows everything.
    private func activeFilter(_ d: Derived) -> String {
        d.classRows.contains { $0.group(by: grouping).key == classFilter } ? classFilter : "all"
    }

    var body: some View {
        let d = derived
        let s = d.summary
        // account view only: the grouped view filters its own cards
        let slice = SliceFilter(selected: classMode ? "all" : classFilter, slices: classMode ? [] : slices(s, d).slices)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Vermögen").appFont(.title2, weight: .semibold)
                    Spacer()
                    #if os(iOS)
                    WealthScopePicker() // macOS: lives in the toolbar
                    #endif
                }
                ownerChips
                // side by side when there is room, else stacked (narrow window, iPhone)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        summaryCard(s, d).frame(maxWidth: 340)
                        compositionCard(s, d)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        summaryCard(s, d)
                        compositionCard(s, d)
                    }
                }
                if classMode {
                    // income and costs come from the depots: next to them in the securities tab,
                    // after the classes where cash and property are listed too
                    if scope == .securities { incomeCard }
                    HStack {
                        Text(LocalizedStringKey(grouping == .instrument ? "Instrumente · Vermögenswerte (brutto)" : "Anlageklassen · Vermögenswerte (brutto)"))
                            .appFont(.subheadline, weight: .semibold)
                        Spacer()
                        Text(Money.format(d.classRows.reduce(0) { $0 + $1.cents })).sensitive().monospacedDigit()
                    }
                    classCards(d)
                    if scope == .all { incomeCard }
                }
                else {
                    // "Alles": a slice is a whole section; in a tab it is one account or position
                    let section = { (id: String) in scope != .all || slice.keeps(id) }
                    if scope == .all || scope == .cash, section("cash") {
                        let cash = scope == .cash ? s.cash.filter { slice.keeps($0.id.description) } : s.cash
                        if !s.cash.isEmpty { cashHistoryCard(s) }
                        listCard("Cash", total: cash.reduce(0) { $0 + $1.balanceCents }, accounts: cash, tint: Theme.inflow)
                    }
                    if scope == .all || scope == .securities, section("\(WealthBucket.securities)") {
                        if scope == .securities { incomeCard }
                        listCard(WealthBucket.securities.title, total: s.cents(.securities), accounts: s.depots, tint: Theme.invest)
                        if scope == .all { incomeCard }
                        positionsCard(total: s.cents(.securities),
                                      positions: scope == .securities ? d.positions.filter { slice.keeps($0.id) } : d.positions)
                    }
                    if scope == .all, section("\(WealthBucket.tangibles)") {
                        listCard(WealthBucket.tangibles.title, total: s.cents(.tangibles), accounts: s.tangibles, tint: Theme.invest)
                    }
                    if scope == .tangibles { tangiblesCard(s, total: s.cents(.tangibles), slice: slice) }
                }
                let debtAccounts = classMode ? s.liabilities.filter { $0.balanceCents < 0 } : s.liabilities
                if scope == .all && !debtAccounts.isEmpty {
                    if classMode {
                        Text(includeLiabilities
                             ? String(localized: "Die Anlageklassen zeigen das Bruttovermögen. Abzüglich der Verbindlichkeiten ergibt sich das Nettovermögen oben.")
                             : String(localized: "Die Anlageklassen zeigen das Bruttovermögen. Verbindlichkeiten sind oben derzeit nicht abgezogen."))
                            .appFont(.caption).foregroundStyle(Theme.secondary)
                    }
                    listCard("Verbindlichkeiten", total: debtAccounts.reduce(0) { $0 + $1.balanceCents }, accounts: debtAccounts, tint: Theme.negative)
                }
                if scope == .all && s.foreignCurrencyCount > 0 {
                    Text("\(s.foreignCurrencyCount) Konten in Fremdwährung sind nicht enthalten.")
                        .appFont(.caption).foregroundStyle(Theme.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
        // positions and transactions can change while the depot total stays the same: a finished
        // sync (last sync time per login) or a new balance date reloads them as well
        // loaded for all owners: switching the owner filters what is already there
        .task(id: positionsKey(allSummary) + ":\(model.assetClassificationVersion)") { await loadPositions(allSummary.depots, tangibles: allSummary.tangibles) }
        .sheet(item: $editingClassification) { request in AssetClassificationSheet(request: request).environment(model) }
        .task(id: historyKey(s)) { await loadHistory(s.cash.map(\.id)) }
        .onAppear {
            // (developer) `--demo-filter wealth:<slice id>`: a selected donut slice for screenshots
            if let wanted = model.options.demoFilter, wanted.hasPrefix("wealth:") { classFilter = String(wanted.dropFirst(7)) }
        }
        .onChange(of: scope) { classFilter = "all" }
        .onChange(of: ownerFilter) { classFilter = "all" }
        .onChange(of: storedGrouping) { classFilter = "all" }
        .onChange(of: hideDirectProperty) { classFilter = "all" }
        .onChange(of: hideUnclassifiedInChart) {
            if hideUnclassifiedInChart && classFilter == Self.unclassifiedKey { classFilter = "all" }
        }
    }

    // MARK: owner filter

    /// One chip per owner with that owner's share of the shown total; hidden while there is nobody to tell apart.
    @ViewBuilder
    private var ownerChips: some View {
        let options = ownerOptions
        if !options.isEmpty {
            let selected = activeOwner
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(options, id: \.self) { option in
                        // the same figure as the summary card would show for this owner: it follows
                        // the tab and the property switch, so the chips split what is on screen
                        let accounts = model.allAccounts.filter(option.keeps)
                        let owned = WealthSummary(accounts: accounts, tangibleIds: Set(accounts.map(\.id).filter { model.isTangible($0) }))
                        let net = WealthAssetSelection(summary: owned, assets: classified, hideDirectProperty: hideDirectProperty)
                            .summary.scoped(to: scope).netCents(includingLiabilities: includeLiabilities)
                        Button { ownerFilter = option } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Group {
                                    switch option {
                                    case .all: Text("Alle")
                                    case .unassigned: Text("Ohne Inhaber")
                                    case .owner(let name): Text(verbatim: name).sensitive()
                                    }
                                }
                                .appFont(.callout, weight: .semibold)
                                Text(Money.format(net)).sensitive()
                                    .appFont(.caption).foregroundStyle(Theme.secondary).monospacedDigit()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(option == selected ? Theme.accent.opacity(0.14) : Theme.neutralTile,
                                        in: RoundedRectangle(cornerRadius: 9))
                            .overlay {
                                RoundedRectangle(cornerRadius: 9)
                                    .stroke(option == selected ? Theme.accent : .clear, lineWidth: 1)
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(option == selected ? .isSelected : [])
                    }
                }
            }
            .accessibilityLabel("Inhaber")
        }
    }

    /// Late bookings can change the history while today's balance stays the same.
    private func historyKey(_ s: WealthSummary) -> String {
        let cash = s.cash.map { "\($0.id):\($0.balanceCents):\($0.transactionCount):\($0.balanceDate)" }.joined(separator: ",")
        return "\(cash)|\(historyDays)|" + syncStamp
    }

    private var syncStamp: String {
        model.connections.map { "\($0.id):\($0.lastSyncUnix ?? 0)" }.joined(separator: ",")
    }

    private func positionsKey(_ s: WealthSummary) -> String {
        let depots = (s.depots + s.tangibles).map { "\($0.id):\($0.balanceCents):\($0.balanceDate)" }.joined(separator: ",")
        return depots + "|" + syncStamp
    }

    // MARK: summary (net worth + assets / liabilities bars)

    private func summaryCard(_ s: WealthSummary, _ d: Derived) -> some View {
        let assets = max(s.grossCents, 0)
        let debts = -min(s.liabilitiesCents, 0)
        let scale = Double(max(assets, debts, 1))
        // direct property of the selected tab; the switch is offered where it can have an effect
        let properties = switch scope {
        case .all: d.selection.directPropertyCount
        case .securities: d.selection.directProperty[.securities] ?? 0
        case .tangibles: d.selection.directProperty[.tangibles] ?? 0
        case .cash: 0
        }
        let offerPropertySwitch = properties > 0 || (scope != .cash && scope != .securities && !fullSummary.tangibles.isEmpty)
        let propertyHidden = hideDirectProperty && properties > 0
        return VStack(alignment: .leading, spacing: 14) {
            Text(scope == .all ? LocalizedStringKey(propertyHidden ? "Nettovermögen ohne Immobilien" : "Nettovermögen") : scope.title)
                .appFont(.caption).foregroundStyle(Theme.secondary)
            Text(Money.format(s.netCents(includingLiabilities: includeLiabilities)))
                .sensitive()
                .font(.system(size: 36, weight: .semibold)).monospacedDigit()
                .minimumScaleFactor(0.6).lineLimit(1)
            if scope == .all {
                bar("Vermögenswerte", assets, Double(assets) / scale, Theme.accent)
                bar("Verbindlichkeiten", -debts, Double(debts) / scale, Theme.negative)
                    .opacity(includeLiabilities ? 1 : 0.45)
            }
            if debts > 0 {
                Toggle("Kredite und Karten abziehen", isOn: $includeLiabilities)
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    .appFont(.callout)
                    #else
                    .toggleStyle(.switch)
                    .appFont(.callout)
                    #endif
            }
            if offerPropertySwitch {
                Toggle("Direkt gehaltene Immobilien ausblenden", isOn: $hideDirectProperty)
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    #else
                    .toggleStyle(.switch)
                    #endif
                    .appFont(.callout)
                if properties == 0 {
                    Text("Gilt für Positionen mit Anlageklasse Immobilien und Instrument Direktbesitz.")
                        .appFont(.caption2).foregroundStyle(Theme.secondary)
                } else if propertyHidden && scope == .all && includeLiabilities && debts > 0 {
                    // no loan is tied to a property: say so instead of showing a silent, too low figure
                    Label("Immobilien sind ausgeblendet, ihre Kredite aber weiterhin abgezogen. Ohne „Kredite und Karten abziehen“ bleibt der Wert vergleichbar.",
                          systemImage: "exclamationmark.triangle.fill")
                        .appFont(.caption2).foregroundStyle(Theme.warning)
                } else if propertyHidden {
                    Text("Immobilien sind aus dieser Ansicht ausgeblendet.")
                        .appFont(.caption2).foregroundStyle(Theme.secondary)
                }
            }
        }
        .card(padding: 18)
    }

    private func bar(_ title: LocalizedStringKey, _ cents: Int64, _ fraction: Double, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).appFont(.subheadline, weight: .medium)
                Spacer()
                Text(Money.format(cents)).sensitive().appFont(.subheadline).monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.neutralTile)
                    Capsule().fill(tint).frame(width: max(g.size.width * fraction, fraction > 0 ? 4 : 0))
                }
            }
            .frame(height: 6)
        }
    }

    // MARK: composition donut

    private func slices(_ s: WealthSummary, _ d: Derived) -> (title: String, slices: [WealthSlice]) {
        if classMode {
            return (String(localized: "Zusammensetzung"), groups(d.classRows).map { group, rows in
                WealthSlice(id: group.key, label: group.title, cents: rows.reduce(0) { $0 + $1.cents },
                            color: group.unclassified ? Theme.secondary : WealthPalette.color(group.order))
            })
        }
        switch scope {
        case .all:
            // one fixed colour per bucket, so the legend colours never collide
            let colors: [WealthBucket: Color] = [.securities: WealthPalette.color(0), .tangibles: WealthPalette.color(2)]
            var out = [WealthSlice(id: "cash", label: String(localized: "Cash"), cents: s.cashCents, color: WealthPalette.color(1))]
            for b in WealthBucket.assetBuckets {
                out.append(WealthSlice(id: "\(b)", label: bucketLabel(b), cents: s.cents(b), color: colors[b] ?? WealthPalette.color(6)))
            }
            // a positive card balance is an asset too, so the donut adds up to the assets bar
            out.append(WealthSlice(id: "credit", label: String(localized: "Kartenguthaben"), cents: s.creditCents, color: WealthPalette.color(3)))
            return (String(localized: "Zusammensetzung"), out.filter { $0.cents > 0 })
        case .cash:
            return (String(localized: "Cash nach Konto"), top(s.cash.map { ($0.id.description, $0.name, $0.balanceCents) }))
        case .securities:
            // securities only: no accounts or tangibles mixed into the positions
            // depots that only report a total (no positions): visible remainder, not 100 % of the known part
            let rest = s.cents(.securities) - d.positions.reduce(0) { $0 + $1.valueCents }
            var parts = top(d.positions.map { ($0.id, $0.name, $0.valueCents) })
            if rest > 0 {
                parts.append(WealthSlice(id: "uncovered", label: String(localized: "Ohne Positionsdaten"), cents: rest, color: Theme.neutralTile))
            }
            return (String(localized: "Wertpapiere nach Position"), parts)
        case .tangibles:
            return (String(localized: "Sachwerte nach Position"),
                    top(tangibleRows(s).map { ($0.id, $0.name, $0.valueCents) }))
        }
    }

    /// Both dimensions name their gap the same way.
    private static let unclassifiedKey = AssetClass.unclassified.key

    /// The rows of each group of the active grouping, in the fixed order of its dimension.
    private func groups(_ rows: [WealthClassRow]) -> [(group: WealthGroup, rows: [WealthClassRow])] {
        Dictionary(grouping: rows) { $0.group(by: grouping) }
            .sorted { $0.key.order < $1.key.order }
            .map { (group: $0.key, rows: $0.value) }
    }

    private func bucketLabel(_ b: WealthBucket) -> String {
        switch b {
        case .cash: String(localized: "Cash")
        case .securities: String(localized: "Wertpapiere")
        case .tangibles: String(localized: "Sachwerte")
        case .liabilities: String(localized: "Verbindlichkeiten")
        }
    }

    /// Largest seven, the rest folded into "Sonstige".
    private func top(_ rows: [(String, String, Int64)]) -> [WealthSlice] {
        let sorted = rows.filter { $0.2 > 0 }.sorted { $0.2 > $1.2 }
        var out = sorted.prefix(7).enumerated().map { WealthSlice(id: $1.0, label: $1.1, cents: $1.2, color: WealthPalette.color($0)) }
        let rest = sorted.dropFirst(7).reduce(Int64(0)) { $0 + $1.2 }
        if rest > 0 { out.append(WealthSlice(id: "rest", label: String(localized: "Sonstige"), cents: rest, color: WealthPalette.rest)) }
        return out
    }

    private func compositionCard(_ s: WealthSummary, _ d: Derived) -> some View {
        let (title, allParts) = slices(s, d)
        let parts = classMode && hideUnclassifiedInChart ? allParts.filter { $0.id != Self.unclassifiedKey } : allParts
        let total = parts.filter { $0.cents > 0 }.reduce(Int64(0)) { $0 + $1.cents }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: title).appFont(.caption).foregroundStyle(Theme.secondary)
                Spacer()
                if parts.contains(where: { $0.id == classFilter }) {
                    Button("Alle anzeigen", systemImage: "xmark.circle.fill") { classFilter = "all" }
                        .buttonStyle(.plain).appFont(.caption).foregroundStyle(Theme.accent)
                }
                if scope != .cash {
                    // always names the active grouping; one more case in `WealthGrouping` is one more entry
                    Picker("Gruppierung", selection: Binding(get: { grouping }, set: { storedGrouping = $0 })) {
                        ForEach(WealthGrouping.available(in: scope)) { Text($0.title(in: scope)).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            if parts.isEmpty {
                Text("Keine Daten").foregroundStyle(Theme.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ViewThatFits(in: .horizontal) {
                    donutRow(parts, total: total, spacing: 36)
                    donutRow(parts, total: total, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            if classMode && allParts.contains(where: { $0.id == Self.unclassifiedKey }) {
                Toggle("Nicht klassifizierte im Diagramm ausblenden", isOn: $hideUnclassifiedInChart)
                    .appFont(.caption)
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    #endif
                if hideUnclassifiedInChart {
                    Text("Diagramm und Anteile zeigen nur zugeordnete Werte. Summen und Positionen bleiben vollständig.")
                        .appFont(.caption2).foregroundStyle(Theme.secondary)
                }
            }
            if scope == .securities && classMode {
                Text(LocalizedStringKey(grouping == .instrument
                     ? "Instrumente innerhalb der Depotkonten; Cash-Konten sind nicht enthalten."
                     : "Anlageklassen innerhalb der Depotkonten; Cash-Konten sind nicht enthalten."))
                    .appFont(.caption2).foregroundStyle(Theme.secondary)
            }
        }
        .card(padding: 18)
    }

    /// Donut and legend, next to each other or (vertical) stacked.
    private func donutRow(_ parts: [WealthSlice], total: Int64, spacing: CGFloat = 36, vertical: Bool = false) -> some View {
        let selected = parts.first { $0.id == classFilter }
        let chart = Chart(parts.filter { $0.cents > 0 }) { p in
            SectorMark(angle: .value("Wert", p.cents), innerRadius: .ratio(0.62), angularInset: 1.5)
                .cornerRadius(3).foregroundStyle(p.color)
                .opacity(selected == nil || p.id == selected?.id ? 1 : 0.25)
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Group {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { location in
                            guard let plot = proxy.plotFrame else { return }
                            let frame = geo[plot]
                            let dx = location.x - frame.midX, dy = location.y - frame.midY
                            let distance = hypot(dx, dy), radius = min(frame.width, frame.height) / 2
                            if distance < radius * 0.62 { classFilter = "all"; return }
                            guard distance <= radius else { return }
                            let radians = atan2(dx, -dy)
                            let angle = Angle.radians(radians < 0 ? radians + 2 * .pi : radians)
                            guard let value: Double = proxy.value(atAngle: angle),
                                  let id = WealthSlice.id(at: value, in: parts) else { return }
                            toggleClassFilter(id)
                        }
                }
            }
        }
        .frame(width: 190, height: 190)
        .overlay {
            VStack(spacing: 0) {
                Text(Money.format(selected?.cents ?? total)).sensitive().appFont(.callout, weight: .semibold).monospacedDigit()
                    .minimumScaleFactor(0.6).lineLimit(1)
                Text(selected == nil ? String(localized: "Summe") : String(localized: "Auswahl"))
                    .appFont(.caption2).foregroundStyle(Theme.secondary)
            }
            .frame(width: 100)
            .allowsHitTesting(false)
        }
        let legend = VStack(alignment: .leading, spacing: 12) {
            ForEach(parts) { p in
                Button { toggleClassFilter(p.id) } label: {
                    legendEntry(p, total: total, selected: selected?.id == p.id)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected?.id == p.id ? .isSelected : [])
                .accessibilityHint("Positionen dieser Gruppe anzeigen oder Filter aufheben")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        return Group {
            if vertical {
                VStack(alignment: .center, spacing: 16) { chart; legend }
            } else {
                HStack(alignment: .center, spacing: spacing) { chart; legend }
            }
        }
    }

    private func legendEntry(_ p: WealthSlice, total: Int64, selected: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle.fill")
                .foregroundStyle(p.color).appFont(.caption2).frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(p.label).sensitive().appFont(.callout, weight: selected ? .semibold : .regular)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Text("\(Money.format(p.cents)) (\((Double(p.cents) / Double(max(total, 1))).formatted(.percent.precision(.fractionLength(1)))))")
                    .sensitive().appFont(.caption).foregroundStyle(Theme.secondary).monospacedDigit()
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    private func toggleClassFilter(_ id: String) {
        classFilter = classFilter == id ? "all" : id
    }

    // MARK: lists

    @ViewBuilder
    private func listCard(_ title: LocalizedStringKey, total: Int64, accounts: [Account], tint: Color) -> some View {
        if !accounts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).appFont(.headline)
                    Spacer()
                    Text(Money.format(total)).sensitive().appFont(.headline).monospacedDigit()
                }
                Divider()
                ForEach(accounts.sorted { abs($0.balanceCents) > abs($1.balanceCents) }, id: \.id) { a in
                    Button { model.interactiveSidebarSelection = .account(a.id) } label: {
                        HStack {
                            Image(systemName: a.sfSymbol).foregroundStyle(tint).frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.name).sensitive().lineLimit(1)
                                if !a.bankName.isEmpty {
                                    Text(a.bankName).appFont(.caption2).foregroundStyle(Theme.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            Text(Money.format(a.balanceCents)).sensitive().monospacedDigit()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .card(padding: 18)
        }
    }

    @ViewBuilder
    private func positionsCard(total: Int64, positions: [WealthPosition]) -> some View {
        let shown = positions
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Positionen aller Depots").appFont(.headline)
                let day = shown.compactMap(\.dayChangeCents)
                let gain = shown.compactMap(\.gainCents)
                if !day.isEmpty || !gain.isEmpty {
                    HStack(spacing: 18) {
                        if !day.isEmpty { change("Heute", day.reduce(0, +)) }
                        if !gain.isEmpty { change("Gewinn/Verlust", gain.reduce(0, +)) }
                    }
                    let cov = WealthPosition.coverage(shown)
                    if cov.day < cov.lines || cov.gain < cov.lines {
                        // sums of the reported values only, not the whole depot value
                        Text("Nur Bestände mit verfügbaren Daten: Heute \(cov.day) von \(cov.lines), Gewinn/Verlust \(cov.gain) von \(cov.lines).")
                            .appFont(.caption).foregroundStyle(Theme.secondary)
                    }
                }
                Divider()
                ForEach(shown) { p in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).sensitive(.labels).lineLimit(1)
                            Text("\(p.quantity.formatted(.number.precision(.fractionLength(0...4)))) · \(p.isin)")
                                .sensitive()
                                .appFont(.caption2).foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(Money.format(p.valueCents)).sensitive().monospacedDigit()
                            if let d = p.dayChangeCents {
                                Text(signed(d)).sensitive().appFont(.caption2).foregroundStyle(tone(d)).monospacedDigit()
                            }
                            if total > 0 {
                                Text((Double(p.valueCents) / Double(total)).formatted(.percent.precision(.fractionLength(1))))
                                    .sensitive()
                                    .appFont(.caption2).foregroundStyle(Theme.secondary).monospacedDigit()
                            }
                        }
                    }
                }
            }
            .card(padding: 18)
        }
    }

    /// One row per tangible item (not sold), with a subline that is never the item's own name.
    struct TangibleRow: Identifiable, Equatable {
        let id: String
        let name: String
        let subtitle: String
        let valueCents: Int64
        /// The item behind the row: navigation, editor and context menu act on it.
        let item: AssetItem
        let symbol: String
        /// Gain or loss against the purchase price; nil while no purchase price is known.
        let gainCents: Int64?
        let gainPercent: Double?
        /// Change since the previous day; automatically priced items only.
        let dayChangeCents: Int64?
        var automatic: Bool { item.setup.priceSource != "manual" }

        init(item: AssetItem, previousUnitCents: Int64? = nil) {
            id = "i\(item.id)"
            name = item.setup.name
            subtitle = WealthView.tangibleSubtitle(item)
            valueCents = item.holding.valueCents
            self.item = item
            symbol = AssetSymbols.symbol(of: item)
            let gain = WealthView.tangibleGain(item)
            gainCents = gain?.cents
            gainPercent = gain?.percent
            dayChangeCents = WealthView.tangibleDayChange(item, previousUnitCents: previousUnitCents)
        }
    }

    /// Gain or loss of a tangible item. The total paid is exact while nothing was sold or added;
    /// after that the per-piece purchase price of the holding applies, like for securities.
    static func tangibleGain(_ item: AssetItem) -> (cents: Int64, percent: Double)? {
        let h = item.holding
        if let paid = item.setup.purchasePriceCents, paid > 0, h.valueCents >= 0,
           h.quantity > 0, h.quantity == item.setup.quantity {
            let (gain, overflow) = h.valueCents.subtractingReportingOverflow(paid)
            if !overflow { return (gain, Double(gain) / Double(paid) * 100) }
        }
        return DepotPositionsView.calculatedGain(h)
    }

    /// Today's price of one piece against yesterday's, times the pieces held; manual items have no
    /// daily price. Per piece, so an unchanged price is exactly 0 (no rounding residue of the total).
    static func tangibleDayChange(_ item: AssetItem, previousUnitCents: Int64?) -> Int64? {
        let h = item.holding
        guard item.setup.priceSource != "manual", !item.sold, let previousUnitCents, previousUnitCents > 0,
              h.currentPriceCents > 0, h.quantity.isFinite, h.quantity > 0 else { return nil }
        let change = (h.quantity * Double(h.currentPriceCents - previousUnitCents)).rounded()
        guard change.isFinite, abs(change) < Double(Int64.max) else { return nil }
        return Int64(change)
    }

    private func tangibleRows(_ s: WealthSummary) -> [TangibleRow] {
        let hiddenIds = hideDirectProperty ? Set(classified.values.flatMap { $0 }.filter(WealthAssetSelection.isDirectProperty).compactMap(\.assetItemId)) : []
        return s.tangibles.flatMap { account in
            model.assetItems(account.id).filter { !$0.sold && !hiddenIds.contains($0.id) }.map { item in
                TangibleRow(item: item, previousUnitCents: tangiblePreviousUnit[item.id])
            }
        }
        .sorted { $0.valueCents > $1.valueCents }
    }

    /// Pieces (when not exactly one), "Edelmetall" for automatically priced items, the note.
    static func tangibleSubtitle(_ item: AssetItem) -> String {
        var parts: [String] = []
        let qty = item.holding.quantity
        if qty != 1 { parts.append(String(localized: "\(qty.formatted(.number.precision(.fractionLength(0...4)))) Stück")) }
        if item.setup.priceSource != "manual" { parts.append(String(localized: "Edelmetall")) }
        if !item.setup.note.isEmpty { parts.append(item.setup.note) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func tangiblesCard(_ s: WealthSummary, total: Int64, slice: SliceFilter) -> some View {
        let rows = tangibleRows(s).filter { slice.keeps($0.id) }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Positionen der Sachwerte").appFont(.headline)
                let day = rows.compactMap(\.dayChangeCents)
                let gain = rows.compactMap(\.gainCents)
                if !day.isEmpty || !gain.isEmpty {
                    HStack(spacing: 18) {
                        if !day.isEmpty { change("Heute", day.reduce(0, +)) }
                        if !gain.isEmpty { change("Gewinn/Verlust", gain.reduce(0, +)) }
                    }
                    // only automatically priced items (gold) have a daily price
                    let automatic = rows.filter(\.automatic).count
                    if day.count < automatic || gain.count < rows.count {
                        Text("Nur Bestände mit verfügbaren Daten: Heute \(day.count) von \(automatic), Gewinn/Verlust \(gain.count) von \(rows.count).")
                            .appFont(.caption).foregroundStyle(Theme.secondary)
                    }
                }
                Divider()
                ForEach(rows) { r in tangibleRow(r, total: total) }
            }
            .card(padding: 18)
        }
    }

    private func tangibleRow(_ r: TangibleRow, total: Int64) -> some View {
        let item = r.item
        let classification = classified[item.accountId]?.first { $0.assetItemId == item.id }?.classification
        return HStack(spacing: 10) {
            AssetSymbolTile(symbol: r.symbol, size: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.name).sensitive().lineLimit(1)
                if !r.subtitle.isEmpty {
                    Text(r.subtitle).sensitive().appFont(.caption2).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Money.format(r.valueCents)).sensitive().monospacedDigit()
                if let cents = r.gainCents, let percent = r.gainPercent {
                    Text(verbatim: Self.gainText(cents: cents, percent: percent))
                        .sensitive().appFont(.caption2).foregroundStyle(tone(cents)).monospacedDigit()
                }
                if total > 0 {
                    Text((Double(r.valueCents) / Double(total)).formatted(.percent.precision(.fractionLength(1))))
                        .sensitive()
                        .appFont(.caption2).foregroundStyle(Theme.secondary).monospacedDigit()
                }
            }
            .lineLimit(1)
            .fixedSize()
        }
        .contentShape(Rectangle())
        // double click first: a single click leaves this view for the account
        .onTapGesture(count: 2) { model.openAssetEditor(accountId: item.accountId, itemId: item.id) }
        .onTapGesture { showTangible(item) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { showTangible(item) }
        .contextMenu {
            if let classification, classification.securityKey != nil {
                Button("Klassifizierung bearbeiten", systemImage: "pencil") {
                    editingClassification = ClassificationEditRequest(name: item.setup.name, classification: classification)
                }
            }
            Button("Sachwert bearbeiten …") { model.openAssetEditor(accountId: item.accountId, itemId: item.id) }
            // gold follows the price API; only manual items carry own values
            if item.setup.priceSource == "manual" {
                Button("Bewertungen bearbeiten …") { model.openAssetAction(.values, itemId: item.id) }
            }
            Button("Anzahl bearbeiten …") { model.openAssetAction(.quantities, itemId: item.id) }
            if !item.sold {
                Button("Sachwert verkaufen …") { model.openAssetAction(.sell, itemId: item.id) }
            }
        }
    }

    /// Opens the item's account with the item selected (its own value chart in the header).
    private func showTangible(_ item: AssetItem) {
        model.interactiveSidebarSelection = .account(item.accountId)
        // `selectAssetItem` toggles: an item that is still selected stays selected
        if model.assetStore.selected != item.id { model.selectAssetItem(item.id) }
    }

    /// "+12,34 € (+5,67 %)".
    static func gainText(cents: Int64, percent: Double) -> String {
        let sign = cents > 0 ? "+" : ""
        return "\(sign)\(Money.format(cents)) (\(sign)\(percent.formatted(.number.precision(.fractionLength(2)))) %)"
    }

    private func classCards(_ d: Derived) -> some View {
        let filter = activeFilter(d)
        let classRows = filter == "all" ? d.classRows : d.classRows.filter { $0.group(by: grouping).key == filter }
        return VStack(alignment: .leading, spacing: 16) {
            if classRows.isEmpty { Text("Keine Daten").foregroundStyle(Theme.secondary) }
            if classRows.contains(where: { $0.cents < 0 }) {
                Text("Negative Werte sind in den Summen enthalten, im Donut werden nur positive Klassenwerte dargestellt.")
                    .appFont(.caption).foregroundStyle(Theme.secondary)
            }
            ForEach(groups(classRows), id: \.group) { group, rows in
                Group {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(group.title).appFont(.headline)
                            Spacer()
                            Text(Money.format(rows.reduce(0) { $0 + $1.cents })).sensitive().monospacedDigit()
                        }
                        Divider()
                        // every open position in one pass: the sheet steps through them
                        let open = ClassificationEditRequest(entries: group.unclassified ? rows.map { .init(name: $0.name, classification: $0.classification) } : [])
                        if !open.entries.isEmpty {
                            HStack {
                                Text(open.entries.count == 1
                                     ? String(localized: "1 Position noch nicht zugeordnet")
                                     : String(localized: "\(open.entries.count) Positionen noch nicht zugeordnet"))
                                    .foregroundStyle(Theme.secondary)
                                Spacer()
                                Button("Jetzt zuordnen") { editingClassification = open }
                                    .buttonStyle(.borderless).foregroundStyle(Theme.accent)
                            }.appFont(.caption)
                        }
                        ForEach(rows) { row in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.name).sensitive(row.scope == .tangibles ? .personal : .labels).lineLimit(1)
                                    Text(row.subtitle(by: grouping))
                                        .appFont(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                                        .help(row.classification.sourceDescription)
                                        .sensitive()
                                }
                                Spacer()
                                Text(Money.format(row.cents)).sensitive().monospacedDigit()
                                if row.classification.securityKey != nil {
                                    Button { editingClassification = ClassificationEditRequest(name: row.name, classification: row.classification) } label: {
                                        Image(systemName: "pencil")
                                    }.buttonStyle(.borderless).help("Klassifizierung bearbeiten")
                                }
                            }
                        }
                    }.card(padding: 18)
                }
            }
        }
    }

    private func signed(_ cents: Int64) -> String { (cents > 0 ? "+" : "") + Money.format(cents) }
    private func tone(_ cents: Int64) -> Color { cents > 0 ? Theme.inflow : (cents < 0 ? Theme.negative : Theme.secondary) }

    private func change(_ title: LocalizedStringKey, _ cents: Int64) -> some View {
        HStack(spacing: 6) {
            Text(title).appFont(.caption).foregroundStyle(Theme.secondary)
            Text(signed(cents)).sensitive().appFont(.callout, weight: .medium).foregroundStyle(tone(cents)).monospacedDigit()
        }
    }

    /// Distributions, fees and taxes of the depots over the last twelve months.
    @ViewBuilder
    private var incomeCard: some View {
        if !income.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Erträge und Kosten").appFont(.headline)
                Text("Letzte 12 Monate, aus den Wertpapierumsätzen der Depots.")
                    .appFont(.caption).foregroundStyle(Theme.secondary)
                Divider()
                incomeRow("Ausschüttungen", income.dividendsCents, Theme.inflow)
                incomeRow("Gebühren", -income.feesCents, Theme.negative)
                incomeRow("Steuern", -income.taxesCents, Theme.negative)
            }
            .card(padding: 18)
        }
    }

    @ViewBuilder
    private func incomeRow(_ title: LocalizedStringKey, _ cents: Int64, _ tint: Color) -> some View {
        if cents != 0 {
            HStack {
                Text(title)
                Spacer()
                Text(Money.format(cents)).sensitive().monospacedDigit().foregroundStyle(tint)
            }
        }
    }

    // MARK: cash history (area chart, back-calculated from bookings)

    private func cashHistoryCard(_ s: WealthSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Cash-Verlauf").appFont(.headline)
                    Text("Aus den Buchungen zurückgerechnet; Depots sind nicht enthalten.")
                        .appFont(.caption).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Picker("Zeitraum", selection: $historyDays) {
                    Text("3 Monate").tag(90)
                    Text("1 Jahr").tag(365)
                    Text("3 Jahre").tag(1095)
                    Text("5 Jahre").tag(1825)
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
            }
            let pts = history.compactMap { p in DateText.date(p.date).map { ($0, Double(p.balanceCents) / 100) } }
            if pts.count < 2 {
                Text("Keine Daten").foregroundStyle(Theme.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                let lo = pts.map(\.1).min() ?? 0, hi = pts.map(\.1).max() ?? 0
                let pad = max((hi - lo) * 0.1, 1)
                Chart {
                    ForEach(pts.indices, id: \.self) { i in
                        AreaMark(x: .value("Datum", pts[i].0), yStart: .value("Basis", lo - pad), yEnd: .value("Cash", pts[i].1))
                            .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.35), Theme.accent.opacity(0.03)],
                                                            startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Datum", pts[i].0), y: .value("Cash", pts[i].1))
                            .foregroundStyle(Theme.accent).lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
                .chartYScale(domain: (lo - pad)...(hi + pad))
                .chartYAxis {
                    AxisMarks(position: .trailing) { v in
                        AxisGridLine()
                        AxisValueLabel { if let d = v.as(Double.self) { Text(Money.format(Int64(d * 100))).sensitive().appFont(.caption2) } }
                    }
                }
                .frame(height: 190)
            }
        }
        .card(padding: 18)
    }

    private func loadHistory(_ ids: [Int64]) async {
        guard !ids.isEmpty else { history = []; return }
        let days = UInt32(historyDays)
        let loaded = try? await model.vaultOffMain { vault in try vault.balanceHistory(accountIds: ids, days: days) }
        if !Task.isCancelled, let loaded { history = loaded }
    }

    private func loadPositions(_ depots: [Account], tangibles: [Account]) async {
        let ids = depots.map(\.id)
        let since = (Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date())
            .formatted(.iso8601.year().month().day())
        // day change of the automatically priced Sachwerte: yesterday's value of one piece
        let yesterday = DateText.iso(Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())
        let priced = tangibles.flatMap { model.assetItems($0.id) }
            .filter { !$0.sold && $0.setup.priceSource != "manual" }.map(\.id)
        let loaded = try? await model.vaultOffMain { vault in
            (try Dictionary(uniqueKeysWithValues: (depots + tangibles).map { ($0.id, try vault.classifiedAssets(accountId: $0.id)) }),
             try ids.flatMap { try vault.listSecurityTransactions(accountId: $0) },
             // a missing price leaves the day change unknown, it does not fail the load
             Dictionary(uniqueKeysWithValues: priced.compactMap { id in
                 ((try? vault.assetUnitValueOn(itemId: id, date: yesterday)) ?? nil).map { (id, $0) }
             }))
        }
        guard !Task.isCancelled else { return }
        if let (assets, transactions, previousUnits) = loaded {
            classified = assets
            tangiblePreviousUnit = previousUnits
            income = WealthIncome.make(transactions, since: since)
            // (developer) `--demo-sheet classification`: the assign queue of the open positions
            if model.options.demoSheet == "classification", editingClassification == nil {
                let open = ClassificationEditRequest(entries: assets.values.flatMap { $0 }
                    .filter { $0.classification.assetClass == .unclassified }
                    .map { .init(name: $0.holding.name, classification: $0.classification) })
                if !open.entries.isEmpty { editingClassification = open }
            }
        }
    }
}
