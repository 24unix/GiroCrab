import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// „Lastschriften“ (#143): the page loads mandates through the core, saves
/// them and prepares a collection.
@MainActor
final class DirectDebitTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
    }

    override func tearDown() async throws { model = nil }

    /// Waits for the background tasks the model starts (saves are async).
    private func settle() async {
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testDemoVaultHasMandatesAndACreditorID() async throws {
        await model.reloadMandates()
        XCTAssertEqual(model.mandates.count, 4)
        XCTAssertEqual(model.creditorID, "DE98ZZZ09999999999")
        XCTAssertEqual(model.mandates.filter(\.active).count, 3)
    }

    /// The demo vault holds one open return, found at Jan Muster's mandate.
    func testDemoReturnIsFoundAtItsMandate() async throws {
        await model.reloadMandates()
        let jan = try XCTUnwrap(model.mandates.first { $0.reference == "M-2025-014" })
        XCTAssertEqual(model.openMandateReturns.map(\.mandateId), [jan.id])
        XCTAssertEqual(model.openMandateReturns.first?.reasonCode, "AC04")
        XCTAssertEqual(model.openMandateReturns.first?.amountCents, -1_250)
    }

    func testSavingADraftAddsAMandateAndRejectsBadInput() async throws {
        await model.reloadMandates()
        model.newMandate()
        var draft = try XCTUnwrap(model.mandateDraft)
        draft.name = "Neu Mitglied"
        draft.iban = "DE00"
        draft.reference = "M-NEU"
        model.mandateDraft = draft
        model.saveMandateDraft()
        await settle()
        XCTAssertNotNil(model.mandateError)   // IBAN invalid
        XCTAssertNotNil(model.mandateDraft)   // sheet stays open

        draft.iban = "DE89 3704 0044 0532 0130 00"
        model.mandateDraft = draft
        model.saveMandateDraft()
        await settle()
        XCTAssertNil(model.mandateError)
        XCTAssertNil(model.mandateDraft)
        await model.reloadMandates()
        XCTAssertEqual(model.mandates.count, 5)
        XCTAssertEqual(model.mandates.first { $0.reference == "M-NEU" }?.nextSequence, "FRST")
    }

    func testCollectionBuildsFilesAndMarkingMovesToFollowUps() async throws {
        await model.reloadMandates()
        model.openCollection()
        XCTAssertEqual(model.collectionLines.count, 3)  // active ones only
        model.buildCollection(dueDate: Calendar.current.date(byAdding: .day, value: 5, to: Date())!)
        await settle()
        XCTAssertNil(model.mandateError, model.mandateError ?? "")
        // CORE/RCUR (Mia), CORE/FRST (Jan), B2B/RCUR (Muster Bau)
        XCTAssertEqual(model.collectionFiles.count, 3)
        XCTAssertTrue(model.collectionFiles.allSatisfy { $0.xml.contains("<PmtMtd>DD</PmtMtd>") })
        let jan = try XCTUnwrap(model.mandates.first { $0.reference == "M-2025-014" })
        XCTAssertEqual(jan.nextSequence, "FRST")
        model.markCollected(model.collectionFiles, dueDate: Date())
        await settle()
        await model.reloadMandates()
        XCTAssertEqual(model.mandates.first { $0.reference == "M-2025-014" }?.nextSequence, "RCUR")
    }

    func testArrowKeysMoveTheMandateSelection() async throws {
        await model.reloadMandates()
        let ids = model.mandates.map(\.id)
        model.moveMandateSelection(1)
        XCTAssertEqual(model.selectedMandateID, ids[0])
        model.moveMandateSelection(-1)
        XCTAssertEqual(model.selectedMandateID, ids[0])
        model.selectedMandateID = ids.last
        model.moveMandateSelection(1)
        XCTAssertEqual(model.selectedMandateID, ids.last)
    }

    func testExportAndPain008ImportRoundTrip() async throws {
        await model.reloadMandates()
        model.exportMandates()
        await settle()
        XCTAssertTrue(model.showMandateExport)
        let csv = String(data: model.mandateExport.data, encoding: .utf8) ?? ""
        XCTAssertTrue(csv.hasPrefix("Name;IBAN;"))
        XCTAssertEqual(csv.split(separator: "\n").count, 5)  // header + 4 mandates

        // a file of this account's own collection can be imported again
        model.openCollection()
        model.buildCollection(dueDate: Calendar.current.date(byAdding: .day, value: 5, to: Date())!)
        await settle()
        let file = try XCTUnwrap(model.collectionFiles.first { $0.sequence == "FRST" })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).xml")
        try file.xml.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        model.importMandateFile(url)
        await settle()
        XCTAssertNil(model.mandateError, model.mandateError ?? "")
        XCTAssertNotNil(model.mandateNote)
    }
}
