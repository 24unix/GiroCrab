import XCTest
@testable import GiroCrabUI

/// The in-app bank login closes only on the real redirect back to GiroCrab.
final class ConsentRedirectTests: XCTestCase {
    private let redirect = ConsentRedirect.defaultURL // https://localhost/girocrab/callback

    func testMatchesTheRedirectWithCodeOrError() throws {
        let ok = try XCTUnwrap(URL(string: "https://localhost/girocrab/callback?code=abc&state=s1"))
        XCTAssertTrue(ConsentRedirect.matches(ok, redirect: redirect))
        let denied = try XCTUnwrap(URL(string: "https://localhost/girocrab/callback?error=access_denied&state=s1"))
        XCTAssertTrue(ConsentRedirect.matches(denied, redirect: redirect))
        // http, upper-case host and a trailing slash are the same place
        let variant = try XCTUnwrap(URL(string: "http://LOCALHOST/girocrab/callback/?code=x"))
        XCTAssertTrue(ConsentRedirect.matches(variant, redirect: redirect))
    }

    func testIgnoresTheBanksOwnPages() throws {
        for s in [
            "https://localhost/girocrab/callback",                 // no answer yet
            "https://localhost/girocrab/callbackX?code=x",         // other path
            "https://localhost/other?code=x",
            "https://banking.c24.de/login?code=x&redirect=https://localhost/girocrab/callback",
            "https://tilisy.enablebanking.com/ais/start?state=s1",
            "girocrab://localhost/girocrab/callback?code=x",       // other scheme
        ] {
            let u = try XCTUnwrap(URL(string: s))
            XCTAssertFalse(ConsentRedirect.matches(u, redirect: redirect), s)
        }
    }

    func testUsesTheConfiguredRedirect() throws {
        let custom = "https://example.org/eb/return"
        XCTAssertTrue(ConsentRedirect.matches(try XCTUnwrap(URL(string: "https://example.org/eb/return?code=1")), redirect: custom))
        XCTAssertFalse(ConsentRedirect.matches(try XCTUnwrap(URL(string: "https://localhost/girocrab/callback?code=1")), redirect: custom))
        XCTAssertFalse(ConsentRedirect.matches(try XCTUnwrap(URL(string: "https://localhost/x?code=1")), redirect: "kein url"))
    }
}
