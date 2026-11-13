import CryptoKit
import XCTest
@testable import GiroCrabUI

/// Signed project announcements: parsing, filtering, signature, rollback, quiet behaviour.
@MainActor
final class AnnouncementsTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()
    private let otherKey = Curve25519.Signing.PrivateKey()
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "announcements-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func pub(_ k: Curve25519.Signing.PrivateKey) -> String { k.publicKey.rawRepresentation.base64EncodedString() }

    private func json(sequence: UInt64 = 1, items: String) -> Data {
        Data(#"{"schema":1,"sequence":\#(sequence),"announcements":[\#(items)]}"#.utf8)
    }

    private let item = #"{"id":"a","severity":"important","title":{"de":"Hallo","en":"Hello"},"summary":{"en":"Short"},"link":"https://example.org/x"}"#

    private func center(version: String = "0.6.1", now: Date = Date(timeIntervalSince1970: 1_800_000_000),
                        distribution: BankingDistribution = .developerID) -> AnnouncementCenter {
        AnnouncementCenter(publicKeys: [pub(key)], fetcher: nil, defaults: defaults,
                           distribution: distribution, version: version, now: { now }, language: { "de" })
    }

    private func sign(_ data: Data, _ k: Curve25519.Signing.PrivateKey? = nil) -> Data {
        try! (k ?? key).signature(for: data)
    }

    func testParseDropsInvalidAndNonHttpsLinks() throws {
        let doc = try AnnouncementsDocument.parse(json(items: item + #",{"id":"","title":{"en":"x"}},{"id":"b","title":{"en":"B"},"link":"http://insecure.example"}"#))
        XCTAssertEqual(doc.announcements.map(\.id), ["a", "b"])
        XCTAssertEqual(doc.announcements[0].severity, .important)
        XCTAssertNotNil(doc.announcements[0].link)
        XCTAssertNil(doc.announcements[1].link)
    }

    func testUnknownSchemaRejected() {
        XCTAssertThrowsError(try AnnouncementsDocument.parse(Data(#"{"schema":2,"sequence":1,"announcements":[]}"#.utf8)))
    }

    func testLanguageFallsBackToEnglish() throws {
        let a = try AnnouncementsDocument.parse(json(items: item)).announcements[0]
        XCTAssertEqual(a.localized(a.title, language: "de"), "Hallo")
        XCTAssertEqual(a.localized(a.summary, language: "de"), "Short")
    }

    func testFilterByDateDistributionAndVersion() throws {
        let doc = try AnnouncementsDocument.parse(json(items: #"{"id":"a","title":{"en":"A"},"from":"2027-01-10","until":"2027-01-20","distribution":["mac-app-store"],"minVersion":"0.6.0","maxVersion":"0.6.9"}"#))
        let inRange = ISO8601DateFormatter().date(from: "2027-01-15T12:00:00Z")!
        XCTAssertEqual(doc.applicable(now: inRange, distribution: .macAppStore, version: "0.6.1").count, 1)
        XCTAssertEqual(doc.applicable(now: inRange, distribution: .developerID, version: "0.6.1").count, 0)
        XCTAssertEqual(doc.applicable(now: inRange, distribution: .macAppStore, version: "0.7.0").count, 0)
        XCTAssertEqual(doc.applicable(now: inRange, distribution: .macAppStore, version: "0.5.9").count, 0)
        XCTAssertEqual(doc.applicable(now: inRange.addingTimeInterval(-10 * 86400), distribution: .macAppStore, version: "0.6.1").count, 0)
        XCTAssertEqual(doc.applicable(now: inRange.addingTimeInterval(10 * 86400), distribution: .macAppStore, version: "0.6.1").count, 0)
    }

    func testInvalidSignatureIsIgnored() {
        let c = center()
        let data = json(items: item)
        c.accept(json: data, signature: sign(data, otherKey))
        XCTAssertNil(c.banner)
    }

    func testValidSignatureShowsBannerAndDismissIsPermanent() {
        let c = center()
        let data = json(items: item)
        c.accept(json: data, signature: sign(data))
        XCTAssertEqual(c.banner?.id, "a")
        c.dismiss(c.banner!)
        XCTAssertNil(c.banner)
        XCTAssertEqual(c.all.count, 1, "dismissed ones stay listed in Hilfe › Mitteilungen")
        // survives a restart
        XCTAssertNil(center().banner)
        XCTAssertEqual(center().all.count, 1)
    }

    func testOnlyOneBannerAtATime() {
        let c = center()
        let data = json(items: item + #",{"id":"b","title":{"en":"B"}}"#)
        c.accept(json: data, signature: sign(data))
        XCTAssertEqual(c.banner?.id, "a")
        c.dismiss(c.banner!)
        XCTAssertEqual(c.banner?.id, "b")
    }

    func testRollbackIgnored() {
        let c = center()
        let new = json(sequence: 5, items: item)
        c.accept(json: new, signature: sign(new))
        let old = json(sequence: 2, items: #"{"id":"old","title":{"en":"Old"}}"#)
        c.accept(json: old, signature: sign(old))
        XCTAssertEqual(c.banner?.id, "a")
    }

    func testDisabledShowsNothing() {
        let c = center()
        let data = json(items: item)
        c.accept(json: data, signature: sign(data))
        c.isEnabled = false
        XCTAssertNil(c.banner)
        XCTAssertTrue(c.all.isEmpty)
        XCTAssertFalse(center().isEnabled, "the choice persists")
    }

    func testPersistedFeedLoadsOfflineAndRejectsTampering() {
        let data = json(items: item)
        center().accept(json: data, signature: sign(data))
        XCTAssertEqual(center().banner?.id, "a")
        defaults.set(json(items: #"{"id":"evil","title":{"en":"Evil"}}"#), forKey: AnnouncementCenter.storedJSONKey)
        XCTAssertNil(center().banner)
    }

    func testNoValidKeyMeansOff() async {
        let c = AnnouncementCenter(publicKeys: ["not-a-key"], fetcher: nil, defaults: defaults, version: "0.6.1")
        await c.refresh()
        XCTAssertNil(c.banner)
    }
}
