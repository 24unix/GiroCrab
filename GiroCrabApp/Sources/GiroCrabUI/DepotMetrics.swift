import Foundation
import SwiftUI
import GiroCrabCore

// Pure figures of the securities depot view (DepotDetailView). No UI state and no vault access, so
// every rule here is covered by DepotMetricsTests. Three data kinds stay apart:
//   holdings (current inventory)  ·  security transactions (activities)  ·  cash bookings (clearing account).
// Nothing in this file reads cash bookings, and positions are never rebuilt from activities.

/// What kind of depot a `brokerage` account is. The single place that decides it
/// (`AppModel.depotKind(of:)`): header, toolbar and content must agree.
enum DepotKind: Equatable {
    case securities
    case tangible
}

extension AccountPresentation {
    /// Label of the ⌘1…⌘3 menu entry: a booking scope, a depot tab, or none for Sachwerte.
    func menuTitle(index: Int, scope: BookingScope) -> String {
        switch self {
        case .bookings: scope.title
        case .securities: DepotTab.allCases.indices.contains(index) ? DepotTab.allCases[index].titleText : "–"
        case .tangible: "–"
        }
    }
}

/// How a holding's price relates to its value.
enum PriceBasis: Equatable {
    /// value ≈ quantity × price (shares, ETFs, certificates)
    case perUnit
    /// value ≈ nominal × price / 100: bonds quote a percentage of the nominal amount
    case percentOfNominal
    /// neither fits (e.g. price in a foreign currency, stale price): no figure derived from it
    case unknown
}

/// A summed figure with the share of positions it is based on.
struct DepotFigure: Equatable {
    var amountCents: Int64 = 0
    /// Reference amount of the percentage: cost basis (P&L) or previous-day value (day change).
    var baseCents: Int64 = 0
    var covered = 0
    var total = 0
    /// Lines whose figure was calculated here instead of delivered by the bank.
    var calculated = 0

    /// Percentage of the summed amounts, never an average of single percentages.
    var percent: Double? { baseCents > 0 ? Double(amountCents) / Double(baseCents) * 100 : nil }
    var isPartial: Bool { covered < total }
}

enum HoldingFigures {
    /// Tolerance when comparing the reported value with quantity × price: rounding and small price lags.
    private static func matches(_ computed: Double, _ value: Int64) -> Bool {
        guard computed.isFinite else { return false }
        return abs(computed - Double(value)) <= max(Double(value) * 0.02, 2)
    }

    static func priceBasis(_ h: Holding, isBond: Bool) -> PriceBasis {
        guard h.quantity.isFinite, h.quantity > 0, h.currentPriceCents > 0, h.valueCents > 0 else { return .unknown }
        let perUnit = h.quantity * Double(h.currentPriceCents)
        if matches(perUnit, h.valueCents) { return .perUnit }
        if isBond, matches(perUnit / 100, h.valueCents) { return .percentOfNominal }
        return .unknown
    }

    struct Gain: Equatable {
        var cents: Int64
        /// Cost basis the gain refers to (value − gain).
        var costCents: Int64
        var reported: Bool
        var percent: Double? { costCents > 0 ? Double(cents) / Double(costCents) * 100 : nil }
    }

    /// Unrealized profit/loss of the current position: the bank's figure first, else value − cost
    /// when the cost price is plausible for the position's price basis.
    static func gain(_ h: Holding, basis: PriceBasis) -> Gain? {
        if let reported = h.profitLossPurchaseCents {
            let (cost, overflow) = h.valueCents.subtractingReportingOverflow(reported)
            guard !overflow else { return nil }
            return Gain(cents: reported, costCents: cost, reported: true)
        }
        switch basis {
        case .perUnit:
            guard let g = calculatedGain(h) else { return nil }
            return Gain(cents: g.cents, costCents: h.valueCents - g.cents, reported: false)
        case .percentOfNominal:
            guard h.purchasePriceCents > 0 else { return nil }
            let cost = (h.quantity * Double(h.purchasePriceCents) / 100).rounded()
            guard cost.isFinite, cost >= 1, cost < Double(Int64.max), h.valueCents >= 0 else { return nil }
            return Gain(cents: h.valueCents - Int64(cost), costCents: Int64(cost), reported: false)
        case .unknown:
            return nil
        }
    }

    struct Day: Equatable {
        var cents: Int64
        var previousValueCents: Int64
    }

    /// Change against the previous day. Only from the bank's previous-day value (or P&L); a previous
    /// value of zero (bought today) is no basis. "Since last sync" is deliberately not used.
    static func dayChange(_ h: Holding) -> Day? {
        if let prev = h.prevDayValueCents, prev > 0 {
            return Day(cents: h.valueCents - prev, previousValueCents: prev)
        }
        if let change = h.profitLossPrevDayCents {
            let prev = h.valueCents - change
            if prev > 0 { return Day(cents: change, previousValueCents: prev) }
        }
        return nil
    }

    /// Derived from existing holdings fields; missing cost prices stay unknown. For positions quoted per piece.
    static func calculatedGain(_ holding: Holding) -> (cents: Int64, percent: Double)? {
        guard holding.quantity.isFinite, holding.quantity > 0,
              holding.purchasePriceCents > 0, holding.valueCents >= 0 else { return nil }
        let cost = (holding.quantity * Double(holding.purchasePriceCents)).rounded()
        guard cost.isFinite, cost >= 1, cost < Double(Int64.max) else { return nil }
        let (gain, overflow) = holding.valueCents.subtractingReportingOverflow(Int64(cost))
        guard !overflow else { return nil }
        return (gain, Double(gain) / cost * 100)
    }

    /// One position as plain text: name, ISIN/WKN, quantity, price, value.
    static func clipboardLine(_ h: Holding) -> String {
        let id = h.isin.isEmpty ? h.wkn : h.isin
        let qty = h.quantity.formatted(.number.precision(.fractionLength(0...4)))
        return [h.name, id, "\(qty) × \(Money.format(h.currentPriceCents))", Money.format(h.valueCents)]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func isBond(_ asset: ClassifiedAsset) -> Bool { asset.classification.assetClass == .bond }

    static func gain(_ asset: ClassifiedAsset) -> Gain? {
        gain(asset.holding, basis: priceBasis(asset.holding, isBond: isBond(asset)))
    }
}

struct DepotValue: Equatable {
    enum Source: Equatable { case reported, positionSum }
    var cents: Int64
    var source: Source
    var positionSumCents: Int64
    var positionCount: Int
    /// reported − sum of positions, only when it exceeds rounding. The clearing account's cash is
    /// never part of either side.
    var differenceCents: Int64?

    /// The depot value is what the bank reports for the depot account (it is also what the sidebar
    /// and the wealth view add up). Without a reported value the position sum stands in; a larger gap
    /// between both is shown, not hidden.
    static func resolve(reportedCents: Int64, holdings: [Holding]) -> DepotValue {
        let sum = holdings.reduce(Int64(0)) { $0 + $1.valueCents }
        if reportedCents == 0, !holdings.isEmpty, sum != 0 {
            return DepotValue(cents: sum, source: .positionSum, positionSumCents: sum, positionCount: holdings.count, differenceCents: nil)
        }
        let diff = reportedCents - sum
        let tolerance = max(Int64(holdings.count), 100)
        let flagged = !holdings.isEmpty && abs(diff) > tolerance
        return DepotValue(cents: reportedCents, source: .reported, positionSumCents: sum, positionCount: holdings.count,
                          differenceCents: flagged ? diff : nil)
    }
}

/// Totals over the current inventory.
enum DepotMetrics {
    static func unrealized(_ assets: [ClassifiedAsset]) -> DepotFigure? {
        unrealized(assets.map { HoldingFigures.gain($0) })
    }

    /// The same figure from gains already worked out (Sachwerte have their own purchase data).
    static func unrealized(_ gains: [HoldingFigures.Gain?]) -> DepotFigure? {
        var f = DepotFigure(total: gains.count)
        for case let g? in gains {
            f.amountCents += g.cents
            f.baseCents += max(g.costCents, 0)
            f.covered += 1
            if !g.reported { f.calculated += 1 }
        }
        return f.covered > 0 ? f : nil
    }

    static func dayChange(_ holdings: [Holding]) -> DepotFigure? {
        var f = DepotFigure(total: holdings.count)
        for h in holdings {
            guard let d = HoldingFigures.dayChange(h) else { continue }
            f.amountCents += d.cents
            f.baseCents += d.previousValueCents
            f.covered += 1
        }
        return f.covered > 0 ? f : nil
    }

    /// Share of one position in the whole current inventory; nil without a positive total.
    static func share(valueCents: Int64, totalCents: Int64) -> Double? {
        totalCents > 0 && valueCents >= 0 ? Double(valueCents) / Double(totalCents) : nil
    }

    /// Name, ISIN or WKN contain every word of the query (case, diacritics and blanks ignored).
    static func matches(query: String, name: String, isin: String, wkn: String) -> Bool {
        matches(query: query, fields: [name, isin, wkn])
    }

    /// Every word of the query occurs in one of the fields (also used for Sachwerte: name and classification).
    static func matches(query: String, fields: [String]) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        let haystack = fields.joined(separator: " ")
        return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

// MARK: positions

enum DepotSortKey: String, CaseIterable, Identifiable {
    case value, gain, name
    var id: String { rawValue }
}

struct DepotSort: Equatable {
    var key: DepotSortKey = .value
    var ascending = false

    /// Header click: the same column flips, a new one starts with its natural direction.
    mutating func toggle(_ new: DepotSortKey) {
        if key == new { ascending.toggle() } else { key = new; ascending = new == .name }
    }
}

struct DepotPosition: Identifiable, Equatable {
    let id: String
    let asset: ClassifiedAsset
    let basis: PriceBasis
    let gain: HoldingFigures.Gain?
    /// Fraction (0…1) of the whole current inventory, independent of any search.
    let share: Double?
    /// No market price to show: one piece of a manually valued item has no price of its own
    /// (the "price" would only repeat the market value).
    var hidesPrice = false
    /// An item the user named himself (Sachwert): its name is personal data.
    var isOwnItem: Bool { asset.assetItemId != nil }
    var holding: Holding { asset.holding }

    var displayName: String {
        holding.name.isEmpty ? (holding.isin.isEmpty ? holding.wkn : holding.isin) : holding.name
    }
    var identifier: String { holding.isin.isEmpty ? holding.wkn : holding.isin }

    /// `gainOf` decides where the gain comes from: securities use the bank's figure or the cost price
    /// (`HoldingFigures.gain`), Sachwerte their own purchase data.
    static func make(_ assets: [ClassifiedAsset], gain gainOf: (ClassifiedAsset) -> HoldingFigures.Gain? = { HoldingFigures.gain($0) },
                     hidesPrice: (ClassifiedAsset) -> Bool = { _ in false }) -> [DepotPosition] {
        let total = assets.reduce(Int64(0)) { $0 + max($1.holding.valueCents, 0) }
        var seen: [String: Int] = [:]
        return assets.map { a in
            let h = a.holding
            let base = "\(h.isin)|\(h.wkn)|\(h.name)|\(h.custodyType)"
            let n = seen[base, default: 0]
            seen[base] = n + 1
            return DepotPosition(id: n == 0 ? base : "\(base)#\(n)", asset: a,
                                 basis: HoldingFigures.priceBasis(h, isBond: HoldingFigures.isBond(a)),
                                 gain: gainOf(a),
                                 share: DepotMetrics.share(valueCents: h.valueCents, totalCents: total),
                                 hidesPrice: hidesPrice(a))
        }
    }

    /// One row per security across several depots: quantity, value, share and gain add up (the gain
    /// over the lines that have one; it counts as reported only if every line is). Classification and
    /// price come from the largest line.
    static func merged(_ items: [DepotPosition]) -> [DepotPosition] {
        let groups = Dictionary(grouping: items) { DepotComposition.key($0.holding) }
        var seen = Set<String>()
        var out: [DepotPosition] = []
        for item in items {
            let key = DepotComposition.key(item.holding)
            guard seen.insert(key).inserted, let group = groups[key] else { continue }
            guard group.count > 1, let lead = group.max(by: { $0.holding.valueCents < $1.holding.valueCents }) else {
                out.append(item)
                continue
            }
            var h = lead.holding
            h.quantity = group.reduce(0) { $0 + $1.holding.quantity }
            h.valueCents = group.reduce(0) { $0 + $1.holding.valueCents }
            h.prevDayValueCents = nil
            h.profitLossPurchaseCents = nil
            let gains = group.compactMap(\.gain)
            let gain = gains.isEmpty ? nil : HoldingFigures.Gain(
                cents: gains.reduce(0) { $0 + $1.cents }, costCents: gains.reduce(0) { $0 + $1.costCents },
                reported: gains.count == group.count && gains.allSatisfy(\.reported))
            let shares = group.compactMap(\.share)
            out.append(DepotPosition(
                id: key, asset: ClassifiedAsset(holding: h, classification: lead.asset.classification, assetItemId: lead.asset.assetItemId),
                basis: lead.basis, gain: gain, share: shares.isEmpty ? nil : shares.reduce(0, +),
                hidesPrice: group.allSatisfy(\.hidesPrice)))
        }
        return out
    }

    /// Positions without a figure always come last, whatever the direction.
    static func sorted(_ items: [DepotPosition], by sort: DepotSort) -> [DepotPosition] {
        func name(_ a: DepotPosition, _ b: DepotPosition) -> Bool {
            a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        }
        func ordered<T: Comparable>(_ a: DepotPosition, _ b: DepotPosition, _ f: (DepotPosition) -> T?) -> Bool {
            switch (f(a), f(b)) {
            case let (x?, y?): return x == y ? name(a, b) : (sort.ascending ? x < y : x > y)
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return name(a, b)
            }
        }
        switch sort.key {
        case .name: return items.sorted { sort.ascending ? name($0, $1) : name($1, $0) }
        case .value: return items.sorted { ordered($0, $1) { $0.holding.valueCents } }
        case .gain: return items.sorted { ordered($0, $1) { $0.gain?.cents } }
        }
    }

    /// Only the positions behind a clicked slice. Whether the filter is stale (none of its keys exists
    /// any more because the inventory changed) is judged against the whole inventory, not against what
    /// the search left: a search that excludes the chosen slice gives an empty list, not everything.
    static func filtered(_ items: [DepotPosition], keys: Set<String>?, inventory: [DepotPosition]? = nil) -> [DepotPosition] {
        guard let keys, (inventory ?? items).contains(where: { keys.contains(DepotComposition.key($0.holding)) }) else { return items }
        return items.filter { keys.contains(DepotComposition.key($0.holding)) }
    }

    static func filtered(_ items: [DepotPosition], query: String) -> [DepotPosition] {
        items.filter { DepotMetrics.matches(query: query, name: $0.holding.name, isin: $0.holding.isin, wkn: $0.holding.wkn) }
    }
}

// MARK: composition

/// The business grouping of a composition: by position, asset class or instrument.
enum DepotCompositionMode: String, CaseIterable, Identifiable {
    case position, assetClass, instrument
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .position: "Nach Position"
        case .assetClass: "Nach Anlageklasse"
        case .instrument: "Nach Instrument"
        }
    }
}

/// How a composition is drawn. Independent of the grouping: every display shows the same slices,
/// the same total and the same percentages.
enum CompositionDisplay: String, CaseIterable, Identifiable {
    case ring, bars, tiles
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .ring: "chart.pie"
        case .bars: "chart.bar.xaxis"
        case .tiles: "square.grid.2x2"
        }
    }
    var title: LocalizedStringKey {
        switch self {
        case .ring: "Kreis"
        case .bars: "Balken"
        case .tiles: "Kacheln"
        }
    }
}

struct DepotSlice: Identifiable, Equatable {
    /// Stable business key (position key, class key, instrument key; "rest" for the folded remainder),
    /// the same in every display.
    let id: String
    let label: String
    let cents: Int64
    /// Positions behind the slice (more than one for a group or the folded remainder).
    let count: Int
    let color: Color
    /// "Nicht klassifiziert": stays in the sum, drawn grey.
    let unclassified: Bool
    /// The label is the user's own name of an item (house, car), not a security or a class: it is
    /// protected like personal data, not only on request.
    var personal = false
    /// The business keys of the positions behind the slice: what a click on it filters the list to.
    var memberKeys: Set<String> = []
    var isRest: Bool { id == DepotComposition.restID }
}

/// Colours of positions. A position's colour starts from a fixed function of its business key
/// (FNV-1a into the palette); positions of the same view that would share a colour step to the next
/// free one, in key order. So the colour never depends on value or rank, the same inventory always
/// looks the same in every display, and up to `palette.count` positions are told apart at a glance.
/// The same security can get another colour in a view with a different inventory only where
/// the starting colours of two positions collide.
enum DepotColors {
    static let palette: [Color] = (0..<8).map { WealthPalette.color($0) } + [
        Color(light: "#7A5C2E", dark: "#C9A66B"), Color(light: "#C95A86", dark: "#F2A3C0"),
        Color(light: "#4A5A9A", dark: "#8FA0E0"), Color(light: "#2E8B8B", dark: "#6FD0D0"),
        Color(light: "#9C4F2E", dark: "#E0936B"), Color(light: "#6B8F3A", dark: "#B5D56B"),
        Color(light: "#8A8A3A", dark: "#D6D68A"), Color(light: "#5F5F7A", dark: "#A9A9C4"),
    ]

    static func startIndex(_ key: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return Int(hash % UInt64(palette.count))
    }

    /// Palette index per key for one inventory: key order decides who steps aside, nothing else.
    static func indices(for keys: [String]) -> [String: Int] {
        var taken = Set<Int>()
        var out: [String: Int] = [:]
        for key in Set(keys).sorted() {
            var i = startIndex(key)
            if taken.count < palette.count {
                while taken.contains(i) { i = (i + 1) % palette.count }
                taken.insert(i)
            }
            out[key] = i
        }
        return out
    }

    static func colors(for keys: [String]) -> [String: Color] { indices(for: keys).mapValues { palette[$0] } }
}

enum DepotComposition {
    static let restID = "rest"
    /// Slices of the ring (the rest is folded into one); the rank list and the tiles show more.
    static let maxPositionSlices = 7
    static let maxRankedSlices = 10
    static let maxTiles = 12

    /// Stable key of a position: what identifies it, not where it currently ranks.
    static func key(_ h: Holding) -> String {
        h.isin.isEmpty ? (h.wkn.isEmpty ? h.name : h.wkn) : h.isin
    }

    /// Positions with a positive value are drawn; the others are listed in `excluded`.
    static func drawable(_ assets: [ClassifiedAsset]) -> [ClassifiedAsset] { assets.filter { $0.holding.valueCents > 0 } }
    static func excludedCount(_ assets: [ClassifiedAsset]) -> Int { assets.count - drawable(assets).count }

    /// All groups with a positive value, largest first. Colours come from the business key alone
    /// (`DepotColors`), never from rank or from what else is held: the same position has the same
    /// colour in every display, in the depot and in the wealth view.
    static func groups(_ assets: [ClassifiedAsset], mode: DepotCompositionMode) -> [DepotSlice] {
        let items = drawable(assets)
        func ordered(_ a: DepotSlice, _ b: DepotSlice) -> Bool {
            a.cents != b.cents ? a.cents > b.cents : a.label.localizedStandardCompare(b.label) == .orderedAscending
        }
        switch mode {
        case .position:
            // one slice per security: the same security in several depots adds up
            var cents: [String: Int64] = [:]
            var labels: [String: String] = [:]
            var own: [String: Bool] = [:]
            let colours = DepotColors.colors(for: items.map { key($0.holding) })
            for a in items {
                let h = a.holding, k = key(h)
                cents[k, default: 0] += h.valueCents
                if labels[k] == nil { labels[k] = h.name.isEmpty ? (h.isin.isEmpty ? h.wkn : h.isin) : h.name }
                if a.assetItemId != nil { own[k] = true }
            }
            return cents.keys.sorted { cents[$0]! != cents[$1]! ? cents[$0]! > cents[$1]! : $0 < $1 }.map { k in
                DepotSlice(id: k, label: labels[k] ?? k, cents: cents[k] ?? 0, count: 1, color: colours[k] ?? Theme.secondary,
                           unclassified: false, personal: own[k] ?? false, memberKeys: [k])
            }
        case .assetClass, .instrument:
            let grouped = Dictionary(grouping: items) { a in
                mode == .assetClass ? WealthGroup.of(a.classification.assetClass) : WealthGroup.of(a.classification.instrument)
            }
            return grouped.map { group, members in
                DepotSlice(id: group.key, label: group.title, cents: members.reduce(0) { $0 + $1.holding.valueCents },
                           count: members.count, color: group.unclassified ? Theme.secondary : WealthPalette.color(group.order),
                           unclassified: group.unclassified, memberKeys: Set(members.map { key($0.holding) }))
            }
            .sorted(by: ordered)
        }
    }

    /// The `keep` largest slices and one "Weitere (n)" slice with the rest: nothing is lost or counted
    /// twice, the sum stays the same.
    static func fold(_ slices: [DepotSlice], keep: Int) -> [DepotSlice] {
        guard slices.count > keep + 1 else { return slices }   // one remaining slice is no "rest"
        let rest = slices.dropFirst(keep)
        let n = rest.reduce(0) { $0 + $1.count }
        return Array(slices.prefix(keep)) + [DepotSlice(
            id: restID, label: String(localized: "Weitere (\(n))"), cents: rest.reduce(0) { $0 + $1.cents },
            count: n, color: WealthPalette.rest, unclassified: false,
            memberKeys: rest.reduce(into: Set<String>()) { $0.formUnion($1.memberKeys) })]
    }

    /// The slices of a ranking with room for `keep` entries: all of them when they fit (a rest of a
    /// single slice is that slice), else the largest `keep` and the rest on its own.
    static func ranked(_ slices: [DepotSlice], keep: Int) -> (shown: [DepotSlice], rest: DepotSlice?) {
        let folded = fold(slices, keep: keep)
        return (folded.filter { !$0.isRest }, folded.last { $0.isRest })
    }

    /// The ring's slices: positions fold after seven, classes and instruments never.
    static func slices(_ assets: [ClassifiedAsset], mode: DepotCompositionMode) -> [DepotSlice] {
        let all = groups(assets, mode: mode)
        return mode == .position ? fold(all, keep: maxPositionSlices) : all
    }
}

/// Squarified treemap: rectangles with areas proportional to the values, in the order given
/// (largest first gives the most readable result). Pure geometry, so it can be tested.
enum Treemap {
    /// `preferredAspect`: in a rectangle much wider than that (width / height), the tiles are laid out in
    /// a rectangle of that shape and stretched to the width, so that a few dozen similar values still
    /// form rows and columns of blocks instead of one row of strips.
    static func layout(_ values: [Double], in rect: CGRect, preferredAspect: Double? = nil) -> [CGRect] {
        if let preferredAspect, rect.height > 0, rect.width > rect.height * preferredAspect {
            let virtual = CGRect(x: 0, y: rect.minY, width: rect.height * preferredAspect, height: rect.height)
            let factor = rect.width / virtual.width
            return layout(values, in: virtual).map { r in
                r == .zero ? r : CGRect(x: rect.minX + r.minX * factor, y: r.minY, width: r.width * factor, height: r.height)
            }
        }
        let positive = values.map { $0.isFinite ? max($0, 0) : 0 }
        let total = positive.reduce(0, +)
        var out = [CGRect](repeating: .zero, count: values.count)
        guard total > 0, rect.width > 0, rect.height > 0 else { return out }
        let scale = Double(rect.width * rect.height) / total
        let areas = positive.map { $0 * scale }
        var free = rect
        var row: [Int] = []

        func worst(_ idx: [Int], side: Double) -> Double {
            let sum = idx.reduce(0) { $0 + areas[$1] }
            guard sum > 0, side > 0, let mx = idx.map({ areas[$0] }).max(), let mn = idx.map({ areas[$0] }).min(), mn > 0 else { return .infinity }
            return max(side * side * mx / (sum * sum), sum * sum / (side * side * mn))
        }
        func place() {
            let sum = row.reduce(0) { $0 + areas[$1] }
            guard sum > 0 else { row = []; return }
            if free.width >= free.height {
                let w = CGFloat(sum) / free.height
                var y = free.minY
                for i in row {
                    let h = CGFloat(areas[i]) / w
                    out[i] = CGRect(x: free.minX, y: y, width: w, height: h)
                    y += h
                }
                free = CGRect(x: free.minX + w, y: free.minY, width: max(free.width - w, 0), height: free.height)
            } else {
                let h = CGFloat(sum) / free.width
                var x = free.minX
                for i in row {
                    let w = CGFloat(areas[i]) / h
                    out[i] = CGRect(x: x, y: free.minY, width: w, height: h)
                    x += w
                }
                free = CGRect(x: free.minX, y: free.minY + h, width: free.width, height: max(free.height - h, 0))
            }
            row = []
        }

        var i = 0
        while i < values.count {
            guard areas[i] > 0 else { i += 1; continue }
            let side = Double(min(free.width, free.height))
            if row.isEmpty || worst(row + [i], side: side) <= worst(row, side: side) {
                row.append(i)
                i += 1
            } else {
                place()
            }
        }
        place()
        return out
    }
}

// MARK: activities

enum DepotActivityFilter: String, CaseIterable, Identifiable {
    case all, buys, sells, distributions, costs
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .all: "Alle"
        case .buys: "Käufe"
        case .sells: "Verkäufe"
        case .distributions: "Ausschüttungen"
        case .costs: "Kosten"
        }
    }

    func keeps(_ t: SecurityTransaction) -> Bool {
        switch self {
        case .all: true
        case .buys: t.direction == .buy
        case .sells: t.direction == .sell
        case .distributions: t.direction == .dividend
        // own fee/tax lines and every activity that carries fees or taxes
        case .costs: t.direction == .fee || t.direction == .tax || t.feesCents != 0 || t.taxesCents != 0
        }
    }
}

enum DepotActivities {
    /// The kind of an activity. The bank's free text never serves as the kind (it can carry personal
    /// data): "Sonstige" stands for everything unclassified, the text only appears protected below.
    static func kindTitle(_ t: SecurityTransaction) -> String {
        switch t.direction {
        case .buy: String(localized: "Kauf")
        case .sell: String(localized: "Verkauf")
        case .dividend: String(localized: "Ausschüttung")
        case .fee: String(localized: "Gebühr")
        case .tax: String(localized: "Steuer")
        case .other: String(localized: "Sonstige")
        }
    }

    /// Fees as shown: an own fee line counts with its amount (its fee field when the value is empty),
    /// fees of trades and distributions as they are. Costs are positive in both columns; only a refund
    /// (a negative fee field) keeps its minus.
    static func feeCents(_ t: SecurityTransaction) -> Int64 {
        t.direction == .fee ? abs(t.valueCents != 0 ? t.valueCents : t.feesCents) : t.feesCents
    }

    static func taxCents(_ t: SecurityTransaction) -> Int64 {
        t.direction == .tax ? abs(t.valueCents != 0 ? t.valueCents : t.taxesCents) : t.taxesCents
    }

    /// ISO dates compare as strings; an open end is `nil`. A transaction without a date has no place in a bounded period.
    static func inPeriod(_ date: String, from: String?, to: String?) -> Bool {
        if from == nil && to == nil { return true }
        guard !date.isEmpty else { return false }
        if let from, date < from { return false }
        if let to, date > to { return false }
        return true
    }

    /// Only this depot's own security transactions (the core keys them by account and external id, so a row
    /// appears once): period, kind and search. Rows keep the store's order (newest first).
    static func filtered(_ all: [SecurityTransaction], accountId: Int64, filter: DepotActivityFilter, query: String,
                         from: String?, to: String?) -> [SecurityTransaction] {
        all.filter { t in
            t.accountId == accountId
                && inPeriod(t.bookingDate, from: from, to: to)
                && filter.keeps(t)
                && DepotMetrics.matches(query: query, name: t.name, isin: t.isin, wkn: t.wkn)
        }
    }
}

/// Distributions, fees and taxes of one depot and period, in one currency.
struct SecurityActivityTotals: Equatable {
    /// Gross: `value_cents` of the distribution lines, before withholding tax.
    var distributionsCents: Int64 = 0
    var distributionCount = 0
    var feesCents: Int64 = 0
    var taxesCents: Int64 = 0
    /// Activities of the period in this currency / in other currencies (not summed: no reliable conversion).
    var count = 0
    var otherCurrencyCount = 0
    var isEmpty: Bool { count == 0 }
    var costsCents: Int64 { feesCents + taxesCents }

    /// Fees and taxes are positive amounts. A fee or tax line counts with its own value (its fee/tax
    /// field only when the value is empty); fee/tax fields of trades and distributions count on top,
    /// but never a second time for a line that already is the fee or the tax.
    static func make(_ transactions: [SecurityTransaction], currency: String, from: String?, to: String?) -> Self {
        var r = Self()
        for t in transactions where DepotActivities.inPeriod(t.bookingDate, from: from, to: to) {
            guard t.currency == currency else { r.otherCurrencyCount += 1; continue }
            r.count += 1
            switch t.direction {
            case .dividend:
                r.distributionsCents += t.valueCents
                r.distributionCount += 1
            case .fee: r.feesCents += t.valueCents != 0 ? abs(t.valueCents) : t.feesCents
            case .tax: r.taxesCents += t.valueCents != 0 ? abs(t.valueCents) : t.taxesCents
            case .buy, .sell, .other: break
            }
            if t.direction != .fee { r.feesCents += t.feesCents }
            if t.direction != .tax { r.taxesCents += t.taxesCents }
        }
        return r
    }
}

/// Segmented switch of the depot view.
enum DepotTab: String, CaseIterable, Identifiable {
    case positions, activities
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .positions: "Positionen"
        case .activities: "Aktivitäten"
        }
    }
    /// For menus and the command palette, which take a String.
    var titleText: String {
        switch self {
        case .positions: String(localized: "Positionen")
        case .activities: String(localized: "Aktivitäten")
        }
    }
}

extension Holding {
    /// The position's own currency when it differs from the account's (#625), else nil.
    /// `currentPriceCents` / `valueCents` stay in the account currency so sums remain correct.
    func nativeCurrency(accountCurrency: String) -> String? {
        currency.isEmpty || currency.caseInsensitiveCompare(accountCurrency) == .orderedSame ? nil : currency
    }
}
