import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// Optional menu bar item (GiroCrab/GiroCrab#546): selection, title and the
/// rule that a locked vault or private mode never shows an amount or a name.
@MainActor
final class MenuBarSummaryTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
    }

    override func tearDown() async throws { model = nil }

    private var accounts: [Account] { model.allAccounts.filter { !$0.isArchived } }

    func testVisibilityFollowsLockAndPrivateMode() {
        XCTAssertEqual(MenuBarSummary.visibility(isUnlocked: false, privateMode: false), .locked)
        // locked wins over private mode
        XCTAssertEqual(MenuBarSummary.visibility(isUnlocked: false, privateMode: true), .locked)
        XCTAssertEqual(MenuBarSummary.visibility(isUnlocked: true, privateMode: true), .covered)
        XCTAssertEqual(MenuBarSummary.visibility(isUnlocked: true, privateMode: false), .visible)
    }

    func testSelectionRoundTripsAndIgnoresGarbage() {
        XCTAssertEqual(MenuBarSummary.decode(MenuBarSummary.encode([3, 1, 2])), [1, 2, 3])
        XCTAssertEqual(MenuBarSummary.decode(""), [])
        XCTAssertEqual(MenuBarSummary.decode("4,x,,7"), [4, 7])
    }

    func testSelectedAccountsKeepAppOrderAndSkipUnknownIDs() throws {
        let all = accounts
        XCTAssertGreaterThanOrEqual(all.count, 2)
        let picked = [all[1].id, all[0].id, 987_654_321]
        let selected = MenuBarSummary.selectedAccounts(model.allAccounts, raw: MenuBarSummary.encode(picked))
        XCTAssertEqual(selected.map(\.id), model.allAccounts.map(\.id).filter { [all[0].id, all[1].id].contains($0) })
        XCTAssertTrue(MenuBarSummary.selectedAccounts(model.allAccounts, raw: "").isEmpty)
    }

    func testTitleShowsFocusedBalanceOrTheSum() throws {
        let selected = Array(accounts.prefix(2))
        let first = try XCTUnwrap(selected.first)
        XCTAssertEqual(MenuBarSummary.title(.visible, selected: selected, focus: String(first.id)),
                       MenuBarSummary.balanceText(first))
        XCTAssertEqual(MenuBarSummary.title(.visible, selected: selected, focus: MenuBarSummary.totalFocus),
                       MenuBarSummary.totalText(of: selected))
        // a focus on an account that is no longer chosen falls back to the sum
        XCTAssertEqual(MenuBarSummary.title(.visible, selected: selected, focus: "987654321"),
                       MenuBarSummary.totalText(of: selected))
        XCTAssertEqual(MenuBarSummary.title(.visible, selected: [], focus: MenuBarSummary.totalFocus), "")
    }

    func testTotalSumsPerCurrency() {
        let selected = accounts.filter { MenuBarSummary.currencyCode($0) == "EUR" }
        let expected = selected.reduce(Int64(0)) { $0 + $1.balanceCents }
        let totals = MenuBarSummary.totals(of: selected)
        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals.first?.cents, expected)
    }

    func testLockedAndPrivateTitlesLeakNeitherAmountsNorNames() {
        let selected = accounts
        for visibility in [MenuBarSummary.Visibility.locked, .covered] {
            for focus in [MenuBarSummary.totalFocus] + selected.map({ String($0.id) }) {
                let title = MenuBarSummary.title(visibility, selected: selected, focus: focus)
                XCTAssertFalse(title.contains(where: \.isNumber), "no digits while \(visibility)")
                for account in selected {
                    XCTAssertFalse(title.contains(account.name), "no account name while \(visibility)")
                    XCTAssertFalse(title.contains(MenuBarSummary.balanceText(account)))
                }
            }
        }
        // locked: nothing next to the crab (the popover says why and offers the unlock)
        XCTAssertEqual(MenuBarSummary.title(.locked, selected: selected, focus: MenuBarSummary.totalFocus), "")
        XCTAssertEqual(MenuBarSummary.title(.covered, selected: selected, focus: MenuBarSummary.totalFocus), "•••")
    }

    func testCycleWalksTheRingAndWrapsAround() {
        let selected = Array(accounts.prefix(3))
        XCTAssertEqual(selected.count, 3)
        let ids = selected.map { String($0.id) }
        let total = MenuBarSummary.totalFocus
        XCTAssertEqual(MenuBarSummary.cycle(focus: total, selected: selected, step: 1), ids[0])
        XCTAssertEqual(MenuBarSummary.cycle(focus: ids[0], selected: selected, step: 1), ids[1])
        XCTAssertEqual(MenuBarSummary.cycle(focus: ids[2], selected: selected, step: 1), total, "wraps to the sum")
        XCTAssertEqual(MenuBarSummary.cycle(focus: total, selected: selected, step: -1), ids[2], "wraps backwards")
        XCTAssertEqual(MenuBarSummary.cycle(focus: ids[0], selected: selected, step: -1), total)
        // an account that is no longer chosen counts as the sum
        XCTAssertEqual(MenuBarSummary.cycle(focus: "987654321", selected: selected, step: 1), ids[0])
        // nothing chosen: stays on the sum
        XCTAssertEqual(MenuBarSummary.cycle(focus: total, selected: [], step: 1), total)
    }

    func testIconOnlyShowsNothingNextToTheIconInEveryState() {
        let selected = accounts
        for visibility in [MenuBarSummary.Visibility.locked, .covered, .visible] {
            XCTAssertEqual(MenuBarSummary.title(visibility, selected: selected, focus: MenuBarSummary.totalFocus, display: .iconOnly), "")
        }
        // amount mode (default) still follows the privacy rule
        XCTAssertEqual(MenuBarSummary.title(.covered, selected: selected, focus: MenuBarSummary.totalFocus, display: .amount), "•••")
        XCTAssertFalse(MenuBarSummary.title(.visible, selected: selected, focus: MenuBarSummary.totalFocus, display: .amount).isEmpty)
        XCTAssertEqual(MenuBarSummary.BarDisplay.allCases.first, .amount, "default: icon and amount")
    }

    func testUpdatedTextShowsOnlyTheTimeForToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "de_DE")
        let now = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00 UTC
        let today = MenuBarSummary.updatedText(now.addingTimeInterval(-3600), now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(today, "07:00")
        let earlier = MenuBarSummary.updatedText(now.addingTimeInterval(-86_400 * 2), now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(earlier.contains("08:00"))
        XCTAssertGreaterThan(earlier.count, today.count, "an earlier day carries its date")
    }

    func testLastUpdateIsTheNewestFetchOfTheShownAccounts() {
        let withLogin = accounts.filter { $0.connectionId != nil }
        XCTAssertFalse(withLogin.isEmpty)
        let latest = MenuBarSummary.lastUpdate(of: withLogin, connections: model.connections)
        let expected = model.connections.filter { c in withLogin.contains { $0.connectionId == c.id } }
            .compactMap(\.lastSyncUnix).max()
        XCTAssertEqual(latest.map { Int64($0.timeIntervalSince1970) }, expected)
        XCTAssertNil(MenuBarSummary.lastUpdate(of: [], connections: model.connections))
    }

    func testNegativeBalancesAreFlagged() {
        for account in accounts {
            XCTAssertEqual(MenuBarSummary.isNegative(account), account.balanceCents < 0)
        }
        let eur = accounts.filter { MenuBarSummary.currencyCode($0) == "EUR" }
        let sum = eur.reduce(Int64(0)) { $0 + $1.balanceCents }
        XCTAssertEqual(MenuBarSummary.totalIsNegative(of: eur), sum < 0)
        XCTAssertFalse(MenuBarSummary.totalIsNegative(of: []), "no accounts, no sign")
    }
}
