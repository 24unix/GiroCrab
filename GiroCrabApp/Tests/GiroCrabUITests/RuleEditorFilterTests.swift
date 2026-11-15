import XCTest
@testable import GiroCrabUI
import GiroCrabCore

final class RuleEditorFilterTests: XCTestCase {
    func testWildcardAndTokenMatching() {
        XCTAssertTrue(RuleSearchMatcher.matches(
            query: "deu*b",
            name: "Deutsche Bahn AG",
            pattern: "DB Fernverkehr",
            categoryPath: "Mobilität › Bahn"
        ))
        XCTAssertTrue(RuleSearchMatcher.matches(
            query: "r?we",
            name: "Supermarkt",
            pattern: "REWE | EDEKA",
            categoryPath: "Alltag › Lebensmittel"
        ))
        XCTAssertTrue(RuleSearchMatcher.matches(
            query: "bahn mobil",
            name: "Deutsche Bahn",
            pattern: "DB",
            categoryPath: "Mobilität"
        ))
        XCTAssertFalse(RuleSearchMatcher.matches(
            query: "netflix",
            name: "Deutsche Bahn AG",
            pattern: "DB Fernverkehr",
            categoryPath: "Mobilität › Bahn"
        ))
    }

    func testRuleReorderingMovesElementCorrectly() {
        let makeRule = { (id: Int64, prio: Int32, name: String) in
            Rule(
                id: id,
                name: name,
                categoryId: 1,
                field: .any,
                matchKind: .keyword,
                pattern: name,
                caseSensitive: false,
                minAmountCents: nil,
                maxAmountCents: nil,
                accountId: nil,
                priority: prio,
                enabled: true,
                matchCount: 0
            )
        }
        let rules = [
            makeRule(1, 10, "Erste"),
            makeRule(2, 20, "Zweite"),
            makeRule(3, 30, "Dritte"),
        ]
        let movedTop = RuleSearchMatcher.move(rules: rules, id: 3, to: 0)
        XCTAssertEqual(movedTop.map(\.id), [3, 1, 2])

        let movedBottom = RuleSearchMatcher.move(rules: rules, id: 1, to: 2)
        XCTAssertEqual(movedBottom.map(\.id), [2, 3, 1])
    }
}
