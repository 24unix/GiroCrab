import Testing
@testable import GiroCrabUI

@Suite struct HeaderTotalTests {
    @Test func sumsOnlyEuroAndListsOthers() {
        let s = HeaderTotal.split([("EUR", 1000), ("USD", 500), ("", 200), ("usd", 100), ("CHF", 7)])
        #expect(s.currency == "EUR")
        #expect(s.cents == 1200)
        #expect(s.others == [.init(currency: "CHF", cents: 7), .init(currency: "USD", cents: 600)])
    }

    @Test func singleForeignCurrencyIsPrimary() {
        let s = HeaderTotal.split([("USD", 500), ("USD", 100)])
        #expect(s.currency == "USD")
        #expect(s.cents == 600)
        #expect(s.others.isEmpty)
    }

    @Test func mixedForeignWithoutEuroKeepsEuroZero() {
        let s = HeaderTotal.split([("USD", 5), ("GBP", 3)])
        #expect(s.currency == "EUR")
        #expect(s.cents == 0)
        #expect(s.others.count == 2)
    }
}
