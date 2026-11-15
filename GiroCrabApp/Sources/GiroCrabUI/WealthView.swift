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
}

enum WealthPalette {
    /// Distinct, colour-blind friendly hues for donut slices (index wraps).
    static let hues: [Color] = [
        Color(light: "#2F6FDB", dark: "#6EA0F5"), Color(light: "#1F7A5C", dark: "#5EC79F"),
        Color(light: "#D98A00", dark: "#F5B94A"), Color(light: "#8E4FC4", dark: "#B98AE6"),
        Color(light: "#D1495B", dark: "#F27F8E"), Color(light: "#0E8FA8", dark: "#5CC6DB"),
        Color(light: "#7A8B99", dark: "#A3B1C4"),
    ]
    static func color(_ i: Int) -> Color { hues[i % hues.count] }
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
    @State private var positions: [WealthPosition] = []
    @State private var income = WealthIncome()
    private var scope: WealthScope { model.wealthScope }
    /// Credit cards and loans reduce the net worth (on by default).
    @AppStorage("wealth.includeLiabilities") private var includeLiabilities = true
    @State private var historyDays = 90
    @State private var history: [DailyBalance] = []

    private var summary: WealthSummary {
        WealthSummary(accounts: model.allAccounts, tangibleIds: Set(model.allAccounts.map(\.id).filter { model.isTangible($0) }))
    }

    var body: some View {
        let s = summary
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Vermögen").appFont(.title2, weight: .semibold)
                    Spacer()
                    #if os(iOS)
                    WealthScopePicker() // macOS: lives in the toolbar
                    #endif
                }
                // side by side when there is room, else stacked (narrow window, iPhone)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        summaryCard(s).frame(maxWidth: 340)
                        compositionCard(s)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        summaryCard(s)
                        compositionCard(s)
                    }
                }
                if scope == .all || scope == .cash { cashHistoryCard(s) }
                if scope == .all || scope == .cash { listCard("Cash", total: s.cashCents, accounts: s.cash, tint: Theme.inflow) }
                if scope == .all || scope == .securities {
                    if scope == .securities { incomeCard }
                    listCard(WealthBucket.securities.title, total: s.cents(.securities), accounts: s.depots, tint: Theme.invest)
                    if scope == .all { incomeCard }
                    positionsCard(total: s.cents(.securities))
                }
                if scope == .all { listCard(WealthBucket.tangibles.title, total: s.cents(.tangibles), accounts: s.tangibles, tint: Theme.invest) }
                if scope == .tangibles { tangiblesCard(total: s.cents(.tangibles)) }
                if scope == .all && !s.liabilities.isEmpty {
                    listCard("Verbindlichkeiten", total: s.cents(.liabilities), accounts: s.liabilities, tint: Theme.negative)
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
        .task(id: positionsKey(s)) { await loadPositions(s.depots) }
        .task(id: historyKey(s)) { await loadHistory(s.cash.map(\.id)) }
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
        let depots = s.depots.map { "\($0.id):\($0.balanceCents):\($0.balanceDate)" }.joined(separator: ",")
        return depots + "|" + syncStamp
    }

    // MARK: summary (net worth + assets / liabilities bars)

    private func summaryCard(_ s: WealthSummary) -> some View {
        let assets = max(s.grossCents, 0)
        let debts = -min(s.liabilitiesCents, 0)
        let scale = Double(max(assets, debts, 1))
        return VStack(alignment: .leading, spacing: 14) {
            Text("Nettovermögen").appFont(.caption).foregroundStyle(Theme.secondary)
            Text(Money.format(s.netCents(includingLiabilities: includeLiabilities)))
                .font(.system(size: 36, weight: .semibold)).monospacedDigit()
                .minimumScaleFactor(0.6).lineLimit(1)
            bar("Vermögenswerte", assets, Double(assets) / scale, Theme.accent)
            bar("Verbindlichkeiten", -debts, Double(debts) / scale, Theme.negative)
                .opacity(includeLiabilities ? 1 : 0.45)
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
        }
        .card(padding: 18)
    }

    private func bar(_ title: LocalizedStringKey, _ cents: Int64, _ fraction: Double, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).appFont(.subheadline, weight: .medium)
                Spacer()
                Text(Money.format(cents)).appFont(.subheadline).monospacedDigit()
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

    private func slices(_ s: WealthSummary) -> (title: String, slices: [WealthSlice]) {
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
            let rest = s.cents(.securities) - positions.reduce(0) { $0 + $1.valueCents }
            var parts = top(positions.map { ($0.id, $0.name, $0.valueCents) })
            if rest > 0 {
                parts.append(WealthSlice(id: "uncovered", label: String(localized: "Ohne Positionsdaten"), cents: rest, color: Theme.neutralTile))
            }
            return (String(localized: "Wertpapiere nach Position"), parts)
        case .tangibles:
            return (String(localized: "Sachwerte nach Position"),
                    top(tangibleRows(s).map { ($0.id, $0.name, $0.valueCents) }))
        }
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
        if rest > 0 { out.append(WealthSlice(id: "rest", label: String(localized: "Sonstige"), cents: rest, color: WealthPalette.color(6))) }
        return out
    }

    private func compositionCard(_ s: WealthSummary) -> some View {
        let (title, parts) = slices(s)
        let total = parts.reduce(Int64(0)) { $0 + $1.cents }
        return VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: title).appFont(.caption).foregroundStyle(Theme.secondary)
            if parts.isEmpty {
                Text("Keine Daten").foregroundStyle(Theme.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ViewThatFits(in: .horizontal) {
                    donutRow(parts, total: total, spacing: 36)
                    donutRow(parts, total: total, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .card(padding: 18)
    }

    /// Donut and legend, next to each other or (vertical) stacked.
    private func donutRow(_ parts: [WealthSlice], total: Int64, spacing: CGFloat = 36, vertical: Bool = false) -> some View {
        let chart = Chart(parts) { p in
            SectorMark(angle: .value("Wert", p.cents), innerRadius: .ratio(0.62), angularInset: 1.5)
                .cornerRadius(3).foregroundStyle(p.color)
        }
        .chartLegend(.hidden)
        .frame(width: 190, height: 190)
        .overlay {
            VStack(spacing: 0) {
                Text(Money.format(total)).appFont(.callout, weight: .semibold).monospacedDigit()
                    .minimumScaleFactor(0.6).lineLimit(1)
                Text("Summe").appFont(.caption2).foregroundStyle(Theme.secondary)
            }
            .frame(width: 100)
        }
        let legend = VStack(alignment: .leading, spacing: 12) {
            ForEach(parts) { p in
                HStack(spacing: 8) {
                    Circle().fill(p.color).frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(p.label).appFont(.callout).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        Text("\(Money.format(p.cents)) (\((Double(p.cents) / Double(max(total, 1))).formatted(.percent.precision(.fractionLength(1)))))")
                            .appFont(.caption).foregroundStyle(Theme.secondary).monospacedDigit()
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
        return Group {
            if vertical {
                VStack(alignment: .center, spacing: 16) { chart; legend }
            } else {
                HStack(alignment: .center, spacing: spacing) { chart; legend }
            }
        }
    }

    // MARK: lists

    @ViewBuilder
    private func listCard(_ title: LocalizedStringKey, total: Int64, accounts: [Account], tint: Color) -> some View {
        if !accounts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).appFont(.headline)
                    Spacer()
                    Text(Money.format(total)).appFont(.headline).monospacedDigit()
                }
                Divider()
                ForEach(accounts.sorted { abs($0.balanceCents) > abs($1.balanceCents) }, id: \.id) { a in
                    Button { model.interactiveSidebarSelection = .account(a.id) } label: {
                        HStack {
                            Image(systemName: a.sfSymbol).foregroundStyle(tint).frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.name).lineLimit(1)
                                if !a.bankName.isEmpty {
                                    Text(a.bankName).appFont(.caption2).foregroundStyle(Theme.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            Text(Money.format(a.balanceCents)).monospacedDigit()
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
    private func positionsCard(total: Int64) -> some View {
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
                            Text(p.name).lineLimit(1)
                            Text("\(p.quantity.formatted(.number.precision(.fractionLength(0...4)))) · \(p.isin)")
                                .appFont(.caption2).foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(Money.format(p.valueCents)).monospacedDigit()
                            if let d = p.dayChangeCents {
                                Text(signed(d)).appFont(.caption2).foregroundStyle(tone(d)).monospacedDigit()
                            }
                            if total > 0 {
                                Text((Double(p.valueCents) / Double(total)).formatted(.percent.precision(.fractionLength(1))))
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
    }

    private func tangibleRows(_ s: WealthSummary) -> [TangibleRow] {
        s.tangibles.flatMap { account in
            model.assetItems(account.id).filter { !$0.sold }.map { item in
                TangibleRow(id: "i\(item.id)", name: item.setup.name,
                            subtitle: WealthView.tangibleSubtitle(item), valueCents: item.holding.valueCents)
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
    private func tangiblesCard(total: Int64) -> some View {
        let rows = tangibleRows(summary)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Positionen der Sachwerte").appFont(.headline)
                Divider()
                ForEach(rows) { r in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.name).lineLimit(1)
                            if !r.subtitle.isEmpty {
                                Text(r.subtitle).appFont(.caption2).foregroundStyle(Theme.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(Money.format(r.valueCents)).monospacedDigit()
                            if total > 0 {
                                Text((Double(r.valueCents) / Double(total)).formatted(.percent.precision(.fractionLength(1))))
                                    .appFont(.caption2).foregroundStyle(Theme.secondary).monospacedDigit()
                            }
                        }
                    }
                }
            }
            .card(padding: 18)
        }
    }

    private func signed(_ cents: Int64) -> String { (cents > 0 ? "+" : "") + Money.format(cents) }
    private func tone(_ cents: Int64) -> Color { cents > 0 ? Theme.inflow : (cents < 0 ? Theme.negative : Theme.secondary) }

    private func change(_ title: LocalizedStringKey, _ cents: Int64) -> some View {
        HStack(spacing: 6) {
            Text(title).appFont(.caption).foregroundStyle(Theme.secondary)
            Text(signed(cents)).appFont(.callout, weight: .medium).foregroundStyle(tone(cents)).monospacedDigit()
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
                Text(Money.format(cents)).monospacedDigit().foregroundStyle(tint)
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
                        AxisValueLabel { if let d = v.as(Double.self) { Text(Money.format(Int64(d * 100))).appFont(.caption2) } }
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
        if let loaded { history = loaded }
    }

    private func loadPositions(_ depots: [Account]) async {
        let ids = depots.map(\.id)
        let since = (Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date())
            .formatted(.iso8601.year().month().day())
        let loaded = try? await model.vaultOffMain { vault in
            (try ids.map { try vault.listHoldings(accountId: $0) },
             try ids.flatMap { try vault.listSecurityTransactions(accountId: $0) })
        }
        if let (holdings, transactions) = loaded {
            positions = WealthPosition.aggregate(holdings)
            income = WealthIncome.make(transactions, since: since)
        }
    }
}
