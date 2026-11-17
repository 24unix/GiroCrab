import XCTest
@testable import GiroCrabUI

/// The transfer sheet takes the height its form needs (#879), within limits.
final class FormFitTests: XCTestCase {
    func testSheetGrowsByWhatTheFormHides() {
        // 700 pt sheet, form shows 500 of 760 pt: the sheet needs 260 pt more.
        let fit = FormFit(content: 760, container: 500, total: 700)
        XCTAssertEqual(fit.height(min: 400, max: 1200), 960)
    }

    func testSheetShrinksToAShortForm() {
        let fit = FormFit(content: 300, container: 500, total: 700)
        XCTAssertEqual(fit.height(min: 400, max: 1200), 500)
    }

    func testHeightStaysWithinLimits() {
        XCTAssertEqual(FormFit(content: 2000, container: 500, total: 700).height(min: 400, max: 1000), 1000)
        XCTAssertEqual(FormFit(content: 50, container: 500, total: 700).height(min: 400, max: 1000), 400)
    }

    func testNoHeightBeforeTheFormWasMeasured() {
        XCTAssertNil(FormFit(content: 0, container: 0, total: 700).height(min: 400, max: 1000))
        XCTAssertNil(FormFit().height(min: 400, max: 1000))
    }
}
