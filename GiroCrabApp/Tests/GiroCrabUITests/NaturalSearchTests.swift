// test: serial-defaults (reads UserDefaults.standard: the natural-search toggle)
import XCTest
import GiroCrabCore
@testable import GiroCrabUI

final class NaturalSearchTests: XCTestCase {
    private let cats: [GiroCrabCore.Category] = [
        GiroCrabCore.Category(id: 1, parentId: nil, name: "Lebensmittel", sfSymbol: "tag", colorHex: "", sortOrder: 0, depth: 0,
                              path: "Lebensmittel", ownTotalCents: 0, totalCents: 0, transactionCount: 0, budgetCents: nil),
        GiroCrabCore.Category(id: 2, parentId: nil, name: "Freizeit", sfSymbol: "tag", colorHex: "", sortOrder: 0, depth: 0,
                              path: "Freizeit", ownTotalCents: 0, totalCents: 0, transactionCount: 0, budgetCents: nil),
    ]
    private func state(_ text: String = "orig") -> NaturalSearchState {
        NaturalSearchState(searchText: text, period: .all, customFrom: "2020-01-01", customTo: "2020-01-31",
                           categoryID: nil, amountFilter: AmountFilter())
    }
    private let today = Date()

    func testDateRangeBecomesCustomPeriod() {
        var s = state()
        NaturalSearch.apply(parsed: ParsedSearchQuery(text: " rewe ", fromDate: "2026-10-01", toDate: "2026-10-31"),
                            to: &s, categories: cats, today: today)
        XCTAssertEqual(s.period, .custom)
        XCTAssertEqual(s.customFrom, "2026-10-01")
        XCTAssertEqual(s.customTo, "2026-10-31")
        XCTAssertEqual(s.searchText, "rewe")
    }

    func testReversedDatesAreSwapped() {
        var s = state()
        NaturalSearch.apply(parsed: ParsedSearchQuery(fromDate: "2026-10-31", toDate: "2026-10-01"),
                            to: &s, categories: cats, today: today)
        XCTAssertEqual(s.customFrom, "2026-10-01")
        XCTAssertEqual(s.customTo, "2026-10-31")
    }

    func testOneSidedDateUsesItForBoth() {
        var s = state()
        NaturalSearch.apply(parsed: ParsedSearchQuery(fromDate: "2026-05-04"), to: &s, categories: cats, today: today)
        XCTAssertEqual(s.customFrom, "2026-05-04")
        XCTAssertEqual(s.customTo, "2026-05-04")
    }

    func testAmountMapsToCentsAndIgnoresNegative() {
        var s = state()
        NaturalSearch.apply(parsed: ParsedSearchQuery(minAmount: 50, maxAmount: 99.99), to: &s, categories: cats, today: today)
        XCTAssertEqual(s.amountFilter, AmountFilter(minCents: 5000, maxCents: 9999))
        var t = state()
        NaturalSearch.apply(parsed: ParsedSearchQuery(minAmount: -5), to: &t, categories: cats, today: today)
        XCTAssertEqual(t, state(), "nothing usable leaves the state untouched")
    }

    func testReversedAmountsAreNormalized() {
        var s = state()
        NaturalSearch.apply(parsed: ParsedSearchQuery(minAmount: 200, maxAmount: 50), to: &s, categories: cats, today: today)
        XCTAssertEqual(s.amountFilter, AmountFilter(minCents: 5000, maxCents: 20000))
    }

    func testCategoryMatching() {
        XCTAssertEqual(NaturalSearch.matchCategory("lebensmittel", in: cats), 1)
        XCTAssertEqual(NaturalSearch.matchCategory("Freiz", in: cats), 2)
        XCTAssertNil(NaturalSearch.matchCategory("Reisen", in: cats))
        XCTAssertNil(NaturalSearch.matchCategory("  ", in: cats))
        var s = state()
        NaturalSearch.apply(parsed: ParsedSearchQuery(categoryName: "Lebensmittel"), to: &s, categories: cats, today: today)
        XCTAssertEqual(s.categoryID, 1)
        XCTAssertEqual(s.searchText, "")
    }

    func testInvalidDateAndUnknownCategoryChangeNothing() {
        var s = state()
        NaturalSearch.apply(parsed: ParsedSearchQuery(text: "", fromDate: "morgen", categoryName: "Nope"),
                            to: &s, categories: cats, today: today)
        XCTAssertEqual(s, state())
    }

    func testLooksNaturalNeedsThreeWordsOrAFillerWord() {
        XCTAssertFalse(NaturalSearch.looksNatural("rewe"))
        XCTAssertFalse(NaturalSearch.looksNatural("rewe berlin"))
        XCTAssertTrue(NaturalSearch.looksNatural("Lebensmittel letzten Monat"))
        XCTAssertTrue(NaturalSearch.looksNatural("zeige amazon"))
        XCTAssertTrue(NaturalSearch.looksNatural("amazon Buchungen"))
    }

    func testKeywordOnlyExtractsTheKeywordWithoutModel() {
        let names = cats.map(\.name)
        XCTAssertEqual(NaturalSearch.keywordOnly("zeige alle amazon", categoryNames: names), "amazon")
        XCTAssertEqual(NaturalSearch.keywordOnly("alle amazon buchungen", categoryNames: names), "amazon")
        XCTAssertEqual(NaturalSearch.keywordOnly("Zeige mir alle Umsätze von Amazon!", categoryNames: names), "Amazon")
        XCTAssertEqual(NaturalSearch.keywordOnly("show all „amazon“ transactions", categoryNames: names), "amazon")
    }

    func testKeywordOnlyLeavesStructuredPhrasesToTheModel() {
        let names = cats.map(\.name)
        XCTAssertNil(NaturalSearch.keywordOnly("amazon", categoryNames: names), "no filler word: literal search")
        XCTAssertNil(NaturalSearch.keywordOnly("zeige alle buchungen", categoryNames: names), "nothing left")
        XCTAssertNil(NaturalSearch.keywordOnly("alle amazon letzten Monat", categoryNames: names))
        XCTAssertNil(NaturalSearch.keywordOnly("alle amazon über 50", categoryNames: names))
        XCTAssertNil(NaturalSearch.keywordOnly("alle buchungen 2025", categoryNames: names))
        XCTAssertNil(NaturalSearch.keywordOnly("zeige alle lebensmittel", categoryNames: names), "a category")
    }

    func testStripFillerWordsDropsPunctuation() {
        XCTAssertEqual(NaturalSearch.stripFillerWords("zeige alle amazon?"), "amazon")
        XCTAssertEqual(NaturalSearch.stripFillerWords("Buchungen: amazon, rewe."), "amazon rewe")
    }

    /// The model echoes the typed phrase unchanged.
    func testUnchangedSentenceFromModelIsStripped() {
        var s = state("zeige alle amazon")
        NaturalSearch.apply(parsed: ParsedSearchQuery(text: "zeige alle amazon"), to: &s, categories: cats, today: today)
        XCTAssertEqual(s.searchText, "amazon")
    }

    /// The model returns an empty text and no filter: the typed phrase without filler words.
    func testEmptyModelTextFallsBackToTypedPhrase() {
        var s = state("alle amazon buchungen")
        NaturalSearch.apply(parsed: ParsedSearchQuery(text: "  "), to: &s, categories: cats, today: today)
        XCTAssertEqual(s.searchText, "amazon")
    }

    /// An empty text next to a recognised filter means the phrase was only that filter.
    func testEmptyModelTextWithFilterClearsSearch() {
        var s = state("Lebensmittel letzten Monat")
        NaturalSearch.apply(parsed: ParsedSearchQuery(text: "", fromDate: "2026-10-01", toDate: "2026-10-31",
                                                      categoryName: "Lebensmittel"),
                            to: &s, categories: cats, today: today)
        XCTAssertEqual(s.searchText, "")
        XCTAssertEqual(s.categoryID, 1)
    }

    /// No model answer (unavailable, error, timeout): `understand` hands back the phrase itself.
    func testNoModelAnswerStillStripsFillerWords() async {
        let parsed = await NaturalSearch.understand("zeige alle amazon", categoryNames: [], today: "2026-11-18")
        XCTAssertEqual(parsed, ParsedSearchQuery(text: "amazon"))
        var s = state("bitte zeige amazon")
        NaturalSearch.apply(parsed: ParsedSearchQuery(text: "bitte zeige amazon"), to: &s, categories: cats, today: today)
        XCTAssertEqual(s.searchText, "bitte amazon")
    }

    func testOnlyFillerWordsChangeNothing() {
        var s = state("zeige alle buchungen")
        NaturalSearch.apply(parsed: ParsedSearchQuery(text: "zeige alle buchungen"), to: &s, categories: cats, today: today)
        XCTAssertEqual(s, state("zeige alle buchungen"))
    }

    func testDisabledByDefault() {
        XCTAssertFalse(UserDefaults.standard.bool(forKey: NaturalSearch.defaultsKey))
        XCTAssertFalse(NaturalSearch.isEnabled)
    }

    func testStripsFillerWordsEvenWithoutStructuredFilters() {
        var state = NaturalSearchState(
            searchText: "alle amazon buchungen",
            period: .all,
            customFrom: "",
            customTo: "",
            categoryID: nil,
            amountFilter: AmountFilter()
        )
        NaturalSearch.apply(
            parsed: ParsedSearchQuery(text: "amazon"),
            to: &state,
            categories: [],
            today: Date()
        )
        XCTAssertEqual(state.searchText, "amazon")
    }
}

/// The rewrite reaches the booking list: search text replaced and the list reloaded for it.
@MainActor
final class NaturalSearchModelTests: XCTestCase {
    func testKeywordPhraseRewritesSearchAndReloadsList() async throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
        model.searchText = "zeige alle amazon"
        model.applyParsedSearch(ParsedSearchQuery(text: "zeige alle amazon"))
        XCTAssertEqual(model.searchText, "amazon")

        let expected = try XCTUnwrap(model.vault).listTransactions(filter: model.currentFilter).transactions.map(\.id)
        XCTAssertFalse(expected.isEmpty, "the demo vault has Amazon bookings")
        for _ in 0..<300 {
            if model.bookings.map(\.id) == expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The list was not reloaded for the rewritten search")
    }
}
