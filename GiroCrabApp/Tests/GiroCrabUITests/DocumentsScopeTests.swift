import XCTest
import GiroCrabCore
@testable import GiroCrabUI

@MainActor
final class DocumentsScopeTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
        XCTAssertNil(model.errorMessage)
    }

    override func tearDown() async throws { model = nil }

    func testOriginAndBookingLinkAreIndependent() throws {
        let vault = try XCTUnwrap(model.vault)
        let all = model.allDocuments()
        let receipts = model.allDocuments(scope: .receipts)
        let postbox = model.allDocuments(scope: .postbox)
        XCTAssertEqual(all.count, 12)
        XCTAssertEqual(Set(receipts.map(\.id)).union(postbox.map(\.id)), Set(all.map(\.id)))
        XCTAssertTrue(Set(receipts.map(\.id)).isDisjoint(with: postbox.map(\.id)))
        for docs in [receipts, postbox] {
            let linked = try XCTUnwrap(docs.first { $0.bookingId != nil })
            XCTAssertTrue(docs.contains { $0.bookingId == nil })
            let scope: DocumentsScope = linked.isBankDocument ? .postbox : .receipts
            try vault.linkDocument(docId: linked.id, bookingId: nil)
            XCTAssertTrue(model.allDocuments(unlinkedOnly: true, scope: scope).contains { $0.id == linked.id })
            // Linking back changes only the booking status, never the origin.
            try vault.linkDocument(docId: linked.id, bookingId: linked.bookingId)
            XCTAssertTrue(model.allDocuments(scope: scope).contains { $0.id == linked.id })
            XCTAssertFalse(model.allDocuments(unlinkedOnly: true, scope: scope).contains { $0.id == linked.id })
        }
    }

    func testAccountOriginSearchAndUnlinkedFiltersCombine() throws {
        let giro = try XCTUnwrap(model.allAccounts.first { $0.name == "Musterbank Girokonto" })
        let card = try XCTUnwrap(model.allAccounts.first { $0.name == "Visa Gold Kreditkarte" })
        let depot = try XCTUnwrap(model.allAccounts.first { $0.name == "Welt-Depot ETF" })
        for account in [giro, card, depot] {
            let docs = model.allDocuments(accountId: account.id, scope: .postbox)
            XCTAssertFalse(docs.isEmpty)
            XCTAssertTrue(docs.allSatisfy { $0.accountId == account.id && $0.isBankDocument })
        }
        let open = model.allDocuments(unlinkedOnly: true, accountId: giro.id, scope: .receipts)
        XCTAssertEqual(open.map(\.title), ["Elektro Weber – Handwerkerrechnung"])
        XCTAssertEqual(model.allDocuments(search: "REWE", accountId: giro.id, scope: .receipts).count, 1)
        XCTAssertTrue(model.allDocuments(search: "REWE", accountId: card.id, scope: .receipts).isEmpty)
        XCTAssertTrue(model.allDocuments(search: "REWE", accountId: giro.id, scope: .postbox).isEmpty)
        XCTAssertTrue(model.allDocuments(accountId: depot.id, scope: .receipts).isEmpty)
        XCTAssertTrue(model.allDocuments(accountId: -42).isEmpty)
    }

    func testDocumentTypeDoesNotDetermineOriginAndLegacyDemoKeysRemainReceipts() throws {
        var doc = try XCTUnwrap(model.allDocuments().first)
        doc.docType = "abrechnung"
        doc.sourceUrl = ""
        XCTAssertTrue(DocumentsScope.receipts.includes(doc))
        doc.sourceUrl = "demo-doc-1"
        XCTAssertTrue(DocumentsScope.receipts.includes(doc))
        doc.docType = "beleg"
        doc.sourceUrl = "moneymoney:account:digest"
        XCTAssertTrue(DocumentsScope.postbox.includes(doc))
    }

    func testUnmatchedUploadStaysAReceiptWithoutAnAccount() throws {
        let vault = try XCTUnwrap(model.vault)
        _ = try vault.autoMatchDocument(fileName: "Unbekannte Rechnung.pdf", bytes: Data("%PDF-1.4\n".utf8), textHint: "Unbekannte Rechnung")
        let receipt = try XCTUnwrap(model.allDocuments(search: "Unbekannte", unlinkedOnly: true, scope: .receipts).first)
        XCTAssertNil(receipt.accountId)
        XCTAssertNil(receipt.bookingId)
        XCTAssertTrue(model.allDocuments(search: "Unbekannte", scope: .postbox).isEmpty)
    }

    /// Dropping a file runs the match off the main thread and still stores it.
    func testDroppedFileIsStoredInTheBackground() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Unbekannter Beleg \(UUID()).pdf")
        try Data("%PDF-1.4\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let version = model.documentsVersion

        XCTAssertTrue(model.dropAnywhere([url]))
        for _ in 0..<300 where model.documentsVersion == version {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(model.documentsVersion, version)
        XCTAssertEqual(model.allDocuments(search: "Unbekannter Beleg", unlinkedOnly: true).count, 1)
        XCTAssertNil(model.errorMessage)
    }
}
