import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// "Neue Überweisung" starts empty; only the sheet's own reopenings keep the draft (#881).
@MainActor
final class TransferDraftTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
        XCTAssertTrue(model.canTransfer)
    }

    override func tearDown() async throws { model = nil }

    private func fillDraft() {
        model.transferDraft.name = "Stadtwerke München"
        model.transferDraft.iban = "DE89 3704 0044 0532 0130 00"
        model.transferDraft.amountText = "85,00"
        model.transferDraft.purpose = "Abschlag"
        model.transferDraft.pin = "12345"
        model.transferDraft.ownTransfer = true
    }

    func testNewTransferStartsEmptyAndKeepsTheAccount() {
        model.openTransfer()
        let account = model.transferDraft.accountID
        XCTAssertNotNil(account)
        fillDraft()
        model.showTransferSheet = false // Abbrechen

        model.openTransfer()
        XCTAssertTrue(model.showTransferSheet)
        XCTAssertEqual(model.transferDraft.accountID, account)
        XCTAssertEqual(model.transferDraft.name, "")
        XCTAssertEqual(model.transferDraft.iban, "")
        XCTAssertEqual(model.transferDraft.amountText, "")
        XCTAssertEqual(model.transferDraft.purpose, "")
        XCTAssertEqual(model.transferDraft.pin, "")
        XCTAssertFalse(model.transferDraft.ownTransfer)
    }

    func testTransferFromBookingReplacesTheOldDraft() throws {
        let booking = try XCTUnwrap(model.bookings.first { $0.amountCents < 0 && !$0.counterparty.isEmpty })
        model.openTransfer()
        fillDraft()
        model.showTransferSheet = false

        model.openTransfer(from: booking)
        XCTAssertEqual(model.transferDraft.name, booking.counterparty)
        XCTAssertEqual(model.transferDraft.amountText, Money.plain(abs(booking.amountCents)))
        XCTAssertEqual(model.transferDraft.pin, "")
        XCTAssertFalse(model.transferDraft.ownTransfer)
    }

    /// Umbuchung chosen in the batch sheet's switch reaches the single form.
    func testUmbuchungFromTheBatchSheetIsKept() async throws {
        model.openBatchTransfer()
        XCTAssertTrue(model.showBatchSheet)
        model.switchTransferKind(to: .own, fromBatch: true)
        for _ in 0..<100 where !model.showTransferSheet { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.showTransferSheet)
        XCTAssertFalse(model.showBatchSheet)
        XCTAssertTrue(model.transferDraft.ownTransfer)
    }

    /// A template or paste in Umbuchung must not leave an own account on screen
    /// while the order goes to the pasted IBAN: it switches to a normal transfer.
    func testTemplateOrPasteLeavesUmbuchung() {
        model.openTransfer()
        model.switchTransferKind(to: .own, fromBatch: false)
        XCTAssertTrue(model.transferDraft.ownTransfer)
        model.fillTransferDraft(ParsedPayment(name: "Stadtwerke München", iban: "DE89370400440532013000",
                                              amountText: "85,00", purpose: "Abschlag"))
        XCTAssertFalse(model.transferDraft.ownTransfer)
        XCTAssertEqual(model.transferDraft.name, "Stadtwerke München")
        XCTAssertEqual(model.transferDraft.iban, "DE89 3704 0044 0532 0130 00")
        XCTAssertEqual(model.transferDraft.amountText, "85,00")
    }

    /// From a savings account only Umbuchung is allowed: a paste brings amount and purpose only.
    func testPasteFromSavingsKeepsTheOwnRecipient() throws {
        model.openTransfer()
        let savings = try XCTUnwrap(model.savingsTransferSources.first)
        model.transferDraft.accountID = savings.id
        model.transferDraft.ownTransfer = true
        model.transferDraft.name = "Erika Mustermann"
        model.transferDraft.iban = "DE89 3704 0044 0532 0130 00"
        model.fillTransferDraft(ParsedPayment(name: "Fremd GmbH", iban: "DE02120300000000202051",
                                              amountText: "12,50", purpose: "Rechnung"))
        XCTAssertTrue(model.transferDraft.ownTransfer)
        XCTAssertEqual(model.transferDraft.name, "Erika Mustermann")
        XCTAssertEqual(model.transferDraft.iban, "DE89 3704 0044 0532 0130 00")
        XCTAssertEqual(model.transferDraft.amountText, "12,50")
        XCTAssertEqual(model.transferDraft.purpose, "Rechnung")
    }

    /// Back from Umbuchung to Überweisung: the own account is not kept as recipient.
    func testLeavingUmbuchungClearsTheOwnRecipient() {
        model.openTransfer()
        model.switchTransferKind(to: .own, fromBatch: false)
        model.transferDraft.name = "Erika Mustermann"
        model.transferDraft.iban = "DE75 5121 0800 1245 1261 99"
        model.switchTransferKind(to: .single, fromBatch: false)
        XCTAssertFalse(model.transferDraft.ownTransfer)
        XCTAssertEqual(model.transferDraft.name, "")
        XCTAssertEqual(model.transferDraft.iban, "")
    }

    /// Name, IBAN and amount are personal: they go with the vault, not only the PIN.
    func testReleasingTheVaultClearsTheDraft() {
        model.openTransfer()
        fillDraft()
        model.releaseVaultState()
        XCTAssertEqual(model.transferDraft.name, "")
        XCTAssertEqual(model.transferDraft.iban, "")
        XCTAssertEqual(model.transferDraft.amountText, "")
        XCTAssertEqual(model.transferDraft.pin, "")
        XCTAssertNil(model.transferDraft.accountID)
    }
}
