import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// The tag window (#228, part 2b): rename, colour, order, merge, delete reach the
/// vault, the tag list and the booking rows.
@MainActor
final class TagManagementTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
        model.period = .all
        XCTAssertNil(model.errorMessage)
    }

    override func tearDown() async throws { model = nil }

    private func tag(_ name: String) throws -> GiroCrabCore.Tag {
        try XCTUnwrap(model.tags.first { $0.name == name }, "no tag \(name)")
    }

    private func rowTags(_ id: Int64) -> [String] {
        model.bookings.first { $0.id == id }?.tags.map(\.name) ?? []
    }

    private var rental: Booking {
        get throws { try XCTUnwrap(model.bookings.first { $0.tags.count == 2 }) }
    }

    func testRenameShowsInTheRows() throws {
        let id = try rental.id
        XCTAssertTrue(model.renameTag(try tag("Urlaub").id, to: "  Urlaub   2026 "))
        XCTAssertNoThrow(try tag("Urlaub 2026"))
        XCTAssertEqual(rowTags(id), ["Auto", "Urlaub 2026"])
    }

    func testRenameRulesMatchTheCore() throws {
        let urlaub = try tag("Urlaub"), auto = try tag("Auto")
        let tags = model.tags
        XCTAssertEqual(AppModel.tagRenameIntent("Urlaub", tags: tags, renaming: urlaub.id), .unchanged)
        XCTAssertEqual(AppModel.tagRenameIntent("URLAUB", tags: tags, renaming: urlaub.id), .rename("URLAUB"),
                       "a change of case only is allowed")
        XCTAssertEqual(AppModel.tagRenameIntent("auto", tags: tags, renaming: urlaub.id), .taken("Auto"))
        XCTAssertEqual(AppModel.tagRenameIntent("Au-to", tags: tags, renaming: urlaub.id), .similar(new: "Au-to", existing: "Auto"))
        XCTAssertEqual(AppModel.tagRenameIntent(" ", tags: tags, renaming: urlaub.id), .empty)
        // what the hint calls taken, the core refuses too
        XCTAssertFalse(model.renameTag(urlaub.id, to: "auto"))
        XCTAssertNotNil(model.errorMessage)
        model.errorMessage = nil
        XCTAssertTrue(model.renameTag(auto.id, to: "AUTO"))
        XCTAssertNoThrow(try tag("AUTO"))
    }

    func testColourShowsInTheRows() throws {
        let id = try rental.id
        model.setTagColor(try tag("Auto").id, hex: "#8E44AD")
        XCTAssertEqual(try tag("Auto").colorHex, "#8E44AD")
        XCTAssertEqual(model.bookings.first { $0.id == id }?.tags.first?.colorHex, "#8E44AD")
        model.setTagColor(try tag("Auto").id, hex: "")
        XCTAssertEqual(try tag("Auto").colorHex, "")
    }

    private var names: [String] { model.tags.map(\.name) }
    private var firstThree: [String] { Array(names.prefix(3)) }
    /// The demo's tags without bookings, by name.
    private let demoUnused = ["Steuererklärung 2026 – Belege für das Finanzamt sammeln", "Umzug 2027"]

    func testArrangedOrderIsStored() throws {
        XCTAssertEqual(firstThree, ["Auto", "Urlaub", "Familie"])
        let id = try rental.id
        model.applyTagOrder(AppModel.tagIDsByName(model.tags))
        XCTAssertEqual(names, names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        // dragged: Urlaub to the top; the rows follow the tag order
        var ids = model.tags.map(\.id)
        ids.move(fromOffsets: [names.firstIndex(of: "Urlaub")!], toOffset: 0)
        model.applyTagOrder(ids)
        XCTAssertEqual(names.first, "Urlaub")
        XCTAssertEqual(rowTags(id), ["Urlaub", "Auto"])
        model.reloadTags()
        XCTAssertEqual(names.first, "Urlaub", "stored in the vault")
    }

    func testDraftIsStoredOnlyWhenApplied() throws {
        let auto = try tag("Auto"), urlaub = try tag("Urlaub"), id = try rental.id
        var ids = model.tags.map(\.id)
        ids.swapAt(0, 1)
        model.tagDraft = TagDraft(renames: [auto.id: "Wagen"], colors: [urlaub.id: "#8E44AD"], order: ids)
        // the sheet shows the draft; the vault, the tag list and the rows don't have it yet
        let shown = AppModel.tagsDrafted(model.tags, model.tagDraft)
        XCTAssertEqual(Array(shown.map(\.name).prefix(2)), ["Wagen", "Urlaub"])
        XCTAssertEqual(shown.first { $0.id == urlaub.id }?.colorHex, "#8E44AD")
        XCTAssertEqual(firstThree, ["Auto", "Urlaub", "Familie"])
        XCTAssertEqual(rowTags(id), ["Auto", "Urlaub"])
        XCTAssertEqual(try tag("Urlaub").colorHex, urlaub.colorHex)

        model.applyTagDraft()
        XCTAssertTrue(model.tagDraft.isEmpty)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(firstThree, ["Urlaub", "Wagen", "Familie"])
        XCTAssertEqual(try tag("Urlaub").colorHex, "#8E44AD")
        XCTAssertEqual(rowTags(id), ["Urlaub", "Wagen"])
        model.reloadTags()
        XCTAssertEqual(firstThree, ["Urlaub", "Wagen", "Familie"], "stored in the vault")
    }

    func testPendingOrderKeepsTagsCreatedOrDeletedMeanwhile() throws {
        let pending = AppModel.tagIDsByName(model.tags)
        let familie = try tag("Familie").id
        model.deleteTags([familie])
        let fresh = try XCTUnwrap(model.tag(named: "Neu"))
        XCTAssertEqual(AppModel.tagOrder(pending, tags: model.tags), pending.filter { $0 != familie } + [fresh.id])
        model.applyTagOrder(pending)
        XCTAssertEqual(model.tags.map(\.id), pending.filter { $0 != familie } + [fresh.id])
    }

    func testRenamesInTheSheetAreStoredOnClosing() throws {
        let auto = try tag("Auto"), urlaub = try tag("Urlaub"), id = try rental.id
        let renames = [auto.id: "Wagen", urlaub.id: "Auto"] // a chain: Urlaub takes the name Auto gives up
        XCTAssertEqual(Array(AppModel.tagsDrafted(model.tags, TagDraft(renames: renames)).map(\.name).prefix(3)),
                       ["Wagen", "Auto", "Familie"])
        XCTAssertEqual(firstThree, ["Auto", "Urlaub", "Familie"], "nothing stored yet")
        XCTAssertTrue(model.applyTagRenames(renames))
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(firstThree, ["Wagen", "Auto", "Familie"])
        XCTAssertEqual(rowTags(id), ["Wagen", "Auto"])
    }

    func testSwappedNamesGoThroughATemporaryName() throws {
        let auto = try tag("Auto"), urlaub = try tag("Urlaub")
        XCTAssertTrue(model.applyTagRenames([auto.id: "Urlaub", urlaub.id: "auto"]))
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(firstThree, ["Urlaub", "auto", "Familie"])
        XCTAssertFalse(names.contains { $0.hasPrefix("~") }, "no temporary name left")
    }

    func testANameHeldOutsideTheSheetIsReportedNotLooped() throws {
        let auto = try tag("Auto")
        XCTAssertFalse(model.applyTagRenames([auto.id: "familie"]))
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(firstThree, ["Auto", "Urlaub", "Familie"])
    }

    func testOrderByBookingsBothWaysTiesByName() throws {
        _ = model.tag(named: "Leer B")
        _ = model.tag(named: "Leer A")
        let empty = (["Leer A", "Leer B"] + demoUnused).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        model.applyTagOrder(AppModel.tagIDsByBookings(model.tags, mostFirst: true))
        let counts = model.tags.map(\.bookingCount)
        XCTAssertEqual(counts, counts.sorted(by: >))
        XCTAssertEqual(Array(names.suffix(empty.count)), empty, "equal counts by name")
        model.applyTagOrder(AppModel.tagIDsByBookings(model.tags, mostFirst: false))
        XCTAssertEqual(model.tags.map(\.bookingCount), counts.sorted())
        XCTAssertEqual(Array(names.prefix(empty.count)), empty)
    }

    func testMergeMovesTheBookingsAndDropsTheSources() throws {
        let a = try XCTUnwrap(model.tag(named: "test-1")), b = try XCTUnwrap(model.tag(named: "test 1"))
        let picked = Array(model.bookings.filter(\.tags.isEmpty).prefix(3))
        model.addTag(a.id, to: [picked[0].id, picked[1].id])
        model.addTag(b.id, to: [picked[1].id, picked[2].id])
        let target = try tag("Familie")
        let before = target.bookingCount

        model.mergeTags([a.id, b.id, target.id], into: target.id)
        XCTAssertNil(model.tags.first { $0.id == a.id })
        XCTAssertNil(model.tags.first { $0.id == b.id })
        XCTAssertEqual(try tag("Familie").bookingCount, before + 3, "a booking with both sources counts once")
        for p in picked { XCTAssertEqual(rowTags(p.id), ["Familie"]) }
    }

    func testDeleteRemovesTheTagFromEveryBookingAndKeepsTheBookings() throws {
        let id = try rental.id, count = model.bookings.count
        model.deleteTags([try tag("Urlaub").id])
        XCTAssertNil(model.tags.first { $0.name == "Urlaub" })
        XCTAssertEqual(rowTags(id), ["Auto"])
        XCTAssertEqual(model.bookings.count, count)
        // a deleted name can be used again: a new tag, not the old one revived
        let again = try XCTUnwrap(model.tag(named: "Urlaub"))
        XCTAssertEqual(again.bookingCount, 0)
    }

    func testRemoveUnusedKeepsUsedTags() throws {
        _ = model.tag(named: "Leer 1")
        _ = model.tag(named: "Leer 2")
        XCTAssertEqual(Set(model.unusedTags.map(\.name)), Set(["Leer 1", "Leer 2"] + demoUnused))
        let used = model.tags.filter { $0.bookingCount > 0 }.map(\.name)
        model.removeUnusedTags()
        XCTAssertTrue(model.unusedTags.isEmpty)
        XCTAssertEqual(names, used)
    }

    func testCreateRefusesATakenNameButAllowsALookAlike() throws {
        let count = model.tags.count
        XCTAssertNil(model.createTag(named: "auto"))
        XCTAssertEqual(model.tags.count, count)
        XCTAssertNotNil(model.createTag(named: "Au-to"))
        XCTAssertEqual(model.tags.count, count + 1)
    }
}
