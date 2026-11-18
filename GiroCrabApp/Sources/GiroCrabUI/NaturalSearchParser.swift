import Foundation
import GiroCrabCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What the on-device model extracted from a search phrase. Plain value type so `NaturalSearch.apply`
/// is testable without a model.
struct ParsedSearchQuery: Equatable, Sendable {
    /// Remaining free text (merchant, purpose); empty when the phrase had nothing else.
    var text: String = ""
    /// ISO days `YYYY-MM-DD`; nil = open on that side.
    var fromDate: String?
    var toDate: String?
    var categoryName: String?
    /// Absolute amounts in euros; nil = open.
    var minAmount: Double?
    var maxAmount: Double?
}

/// The filter state a parsed query may change (a value copy of the matching `AppModel` properties).
struct NaturalSearchState: Equatable {
    var searchText: String
    var period: Period
    var customFrom: String
    var customTo: String
    var categoryID: Int64?
    var amountFilter: AmountFilter
}

/// Optional on-device natural-language search (Apple FoundationModels, Einstellungen › Allgemein).
/// Privacy: only the typed search text, today's date and the category names reach the model, never
/// bookings, balances or IBANs; the model runs on the device.
enum NaturalSearch {
    static let defaultsKey = "search.naturalLanguage"
    /// Text the model wrote back into the search field (not parsed again).
    static var lastRewrite: String?

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    /// Opt-in, off by default.
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) && isAvailable }

    /// A phrase worth refining: three or more words, or two when one is a filler word
    /// ("zeige amazon", "amazon buchungen").
    static func looksNatural(_ query: String) -> Bool {
        let words = tokens(query)
        if words.count >= 3 { return true }
        return words.count == 2 && words.contains { fillerWords.contains($0.lowercased()) }
    }

    private static let fillerWords: Set<String> = [
        "zeige", "zeig", "mir", "alle", "sämtliche", "saemtliche",
        "buchungen", "buchung", "umsätze", "umsaetze", "umsatz",
        "zahlungen", "zahlung", "transaktionen", "transaktion",
        "ausgaben", "einnahmen", "von", "bei", "fuer", "für", "mit", "nach", "suche",
        "show", "me", "all", "transactions", "transaction", "payments", "bookings", "find", "search", "for", "from"
    ]

    /// Words of a phrase without separators and surrounding punctuation or quotes.
    private static func tokens(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ":" || $0 == ";" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".!?\"'„“”‚‘’»«")) }
            .filter { !$0.isEmpty }
    }

    /// Strips conversational wrapper words (e.g. "zeige alle amazon" -> "amazon").
    static func stripFillerWords(_ raw: String) -> String {
        tokens(raw).filter { !fillerWords.contains($0.lowercased()) }.joined(separator: " ")
    }

    /// Words that point at a period, an amount or a direction: such a phrase needs the model.
    private static let structuredWords: Set<String> = [
        "heute", "gestern", "vorgestern", "letzten", "letzte", "letzter", "letztes", "vorigen", "vorige",
        "diesen", "diese", "dieser", "dieses", "seit", "bis", "zwischen", "über", "ueber", "unter", "ab",
        "mehr", "weniger", "als", "euro", "eur", "€",
        "tag", "tage", "tagen", "woche", "wochen", "monat", "monate", "monaten", "monats",
        "quartal", "jahr", "jahre", "jahren", "jahres",
        "januar", "februar", "märz", "maerz", "april", "mai", "juni", "juli", "august",
        "september", "oktober", "november", "dezember",
        "today", "yesterday", "last", "this", "since", "until", "between", "over", "under", "above", "below",
        "more", "less", "than", "day", "days", "week", "weeks", "month", "months", "year", "years", "quarter",
        "january", "february", "march", "may", "june", "july", "october", "december"
    ]

    /// A pure keyword search wrapped in filler words ("zeige alle amazon", "alle amazon buchungen"):
    /// the keyword, without asking the model. Nil when the phrase also names a period, an amount,
    /// a number or one of the categories, or when nothing but filler words is left.
    static func keywordOnly(_ query: String, categoryNames: [String]) -> String? {
        let words = tokens(query)
        let kept = words.filter { !fillerWords.contains($0.lowercased()) }
        guard !kept.isEmpty, kept.count < words.count else { return nil }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        for word in kept {
            if structuredWords.contains(word.lowercased()) { return nil }
            if word.contains(where: \.isNumber) || word.contains("€") { return nil }
            if categoryNames.contains(where: { $0.compare(word, options: opts) == .orderedSame }) { return nil }
        }
        return kept.joined(separator: " ")
    }

    /// Maps a parsed query onto the filters. Unknown categories, invalid dates and negative or
    /// non-finite amounts are ignored; with nothing usable the state stays untouched.
    static func apply(parsed: ParsedSearchQuery, to state: inout NaturalSearchState,
                      categories: [GiroCrabCore.Category], today: Date) {
        var next = state
        var found = false

        let from = parsed.fromDate.flatMap(DateText.parseISODay)
        let to = parsed.toDate.flatMap(DateText.parseISODay)
        if from != nil || to != nil {
            var a = from ?? to!, b = to ?? from!
            if a > b { swap(&a, &b) }
            next.period = .custom
            next.customFrom = DateText.iso(a)
            next.customTo = DateText.iso(b)
            found = true
        }

        if let name = parsed.categoryName, let id = matchCategory(name, in: categories) {
            next.categoryID = id
            found = true
        }

        let lo = cents(parsed.minAmount), hi = cents(parsed.maxAmount)
        if lo != nil || hi != nil {
            next.amountFilter = AmountFilter(minCents: lo, maxCents: hi).normalized
            found = true
        }

        let currentTrimmed = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = stripFillerWords(parsed.text)
        // The model found neither a filter nor a keyword (empty text): the typed phrase without
        // its filler words is still the best keyword ("zeige alle amazon" -> "amazon").
        if text.isEmpty && !found { text = stripFillerWords(currentTrimmed) }
        let textChanged = !text.isEmpty && text.caseInsensitiveCompare(currentTrimmed) != .orderedSame
        guard found || textChanged else { return }
        next.searchText = text
        state = next
    }

    private static func cents(_ euros: Double?) -> Int64? {
        guard let euros, euros.isFinite, euros >= 0, euros < 1e9 else { return nil }
        return Int64((euros * 100).rounded())
    }

    /// Exact (case-insensitive) name first, then a unique partial match.
    static func matchCategory(_ name: String, in categories: [GiroCrabCore.Category]) -> Int64? {
        let q = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if let hit = categories.first(where: { $0.name.compare(q, options: opts) == .orderedSame }) { return hit.id }
        let partial = categories.filter { $0.name.range(of: q, options: opts) != nil }
        return partial.count == 1 ? partial[0].id : nil
    }

    /// The filters for a phrase: a pure keyword search directly, everything else from the
    /// on-device model. Without a model answer (unavailable, error, timeout) the phrase itself,
    /// which `apply` then strips of its filler words.
    static func understand(_ query: String, categoryNames: [String], today: String) async -> ParsedSearchQuery {
        if let keyword = keywordOnly(query, categoryNames: categoryNames) { return ParsedSearchQuery(text: keyword) }
        return await parse(query, categoryNames: categoryNames, today: today) ?? ParsedSearchQuery(text: query)
    }

    /// Asks the on-device model; nil on any failure or after 8 s.
    static func parse(_ query: String, categoryNames: [String], today: String) async -> ParsedSearchQuery? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, iOS 26, *), isAvailable else { return nil }
        return await withTaskGroup(of: ParsedSearchQuery?.self) { group in
            group.addTask { await generate(query, categoryNames: categoryNames, today: today) }
            group.addTask { try? await Task.sleep(nanoseconds: 8_000_000_000); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #else
        return nil
        #endif
    }
}

#if canImport(FoundationModels)
@available(macOS 26, iOS 26, *)
@Generable
struct GeneratedSearchQuery {
    @Guide(description: "Remaining core search keyword (merchant, purpose) stripped of filler words like alle, buchungen, umsaetze, show, transactions, and without period, category or amount words; empty if none")
    var text: String
    @Guide(description: "Start of the period as YYYY-MM-DD, only if the phrase names a period")
    var fromDate: String?
    @Guide(description: "End of the period as YYYY-MM-DD, only if the phrase names a period")
    var toDate: String?
    @Guide(description: "Exactly one name from the given category list, only if the phrase names it")
    var categoryName: String?
    @Guide(description: "Lower amount limit in euros (positive number), e.g. for 'over 50'")
    var minAmount: Double?
    @Guide(description: "Upper amount limit in euros (positive number), e.g. for 'under 20'")
    var maxAmount: Double?
}

@available(macOS 26, iOS 26, *)
private func generate(_ query: String, categoryNames: [String], today: String) async -> ParsedSearchQuery? {
    // Only these three inputs leave the app's own data: search text, today's date, category names.
    let session = LanguageModelSession(instructions: """
        You turn a bookkeeping search phrase into filters. Today is \(today). \
        Categories: \(categoryNames.joined(separator: ", ")). \
        Resolve relative periods (last month, this year) to concrete dates. Never invent values. \
        A merchant, shop or person name (e.g. a store or online shop) always goes into text, \
        never into categoryName unless the phrase names that category itself.
        """)
    guard let out = try? await session.respond(to: query, generating: GeneratedSearchQuery.self).content
    else { return nil }
    return ParsedSearchQuery(text: out.text, fromDate: out.fromDate, toDate: out.toDate,
                             categoryName: out.categoryName, minAmount: out.minAmount, maxAmount: out.maxAmount)
}
#endif
