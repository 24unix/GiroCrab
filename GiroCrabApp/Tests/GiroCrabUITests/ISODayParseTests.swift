import XCTest
@testable import GiroCrabUI

final class ISODayParseTests: XCTestCase {
    private let reference: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The hand parser must give the formatter's midnight for every day of 20 years
    /// (leap days and the time zone's DST changes included) and reject what it rejects.
    func testMatchesTheDateFormatterForTwentyYears() {
        let cal = Calendar(identifier: .gregorian)
        var date = cal.date(from: DateComponents(year: 2010, month: 1, day: 1))!
        for _ in 0..<(366 * 20) {
            let s = reference.string(from: date)
            XCTAssertEqual(DateText.parseISODay(s), reference.date(from: s), s)
            date = cal.date(byAdding: .day, value: 1, to: date)!
        }
        XCTAssertEqual(DateText.parseISODay("2000-02-29"), reference.date(from: "2000-02-29"))
    }

    func testRejectsMalformedDays() {
        for s in ["", "2026-13-01", "2026-00-10", "2026-02-30", "2025-02-29", "2026-1-01", "26-01-01", "2026/01/01", "2026-01-0a", "2026-01-011"] {
            XCTAssertNil(DateText.parseISODay(s), s)
            XCTAssertEqual(DateText.date(s), reference.date(from: s), "falls back to the formatter for \(s)")
        }
    }
}
