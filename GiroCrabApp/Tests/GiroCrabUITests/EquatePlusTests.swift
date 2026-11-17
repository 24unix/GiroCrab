import XCTest
import GiroCrabCore
@testable import GiroCrabUI

final class EquatePlusTests: XCTestCase {
    func testCatalogAndPortalRouting() throws {
        let bank = try XCTUnwrap(bankCatalog().first { $0.kind == .equatePlus })
        XCTAssertEqual(bank.name, "EquatePlus")
        XCTAssertTrue(bank.requiredSettings.isEmpty)
        XCTAssertEqual(ConnectorKind.equatePlus.portalURL?.scheme, "https")
        XCTAssertEqual(ConnectorKind.equatePlus.portalURL?.host, "www.equateplus.com")
        XCTAssertTrue(ConnectorKind.equatePlus.portalHosts.contains("www.emea.equateplus.com"))
        XCTAssertTrue(ConnectorKind.equatePlus.portalHosts.contains("www.na.equateplus.com"))
    }
}
