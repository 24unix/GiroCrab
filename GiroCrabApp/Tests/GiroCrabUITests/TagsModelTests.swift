import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// Booking tags in the app model (#228): the rows show a change at once and match the vault.
@MainActor
final class TagsModelTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
        XCTAssertNil(model.errorMessage)
        // every demo booking in the list (synchronous: not an interactive change)
        model.period = .all
        XCTAssertFalse(model.bookings.isEmpty)
    }

    override func tearDown() async throws { model = nil }

    private func row(_ id: Int64) throws -> Booking {
        try XCTUnwrap(model.bookings.first { $0.id == id })
    }

    /// Tag names of the booking as the vault has them.
    private func stored(_ id: Int64) throws -> [String] {
        let page = try XCTUnwrap(model.vault).listTransactions(filter: model.currentFilter)
        return try XCTUnwrap(page.transactions.first { $0.id == id }).tags.map(\.name)
    }

    private func untagged(_ n: Int) throws -> [Booking] {
        let found = Array(model.bookings.filter(\.tags.isEmpty).prefix(n))
        XCTAssertEqual(found.count, n)
        return found
    }

    func testDemoTagsAreLoadedAndShownOnTheRows() throws {
        XCTAssertEqual(model.tags.map(\.name), ["Auto", "Urlaub", "Familie"])
        XCTAssertTrue(model.tags.allSatisfy { $0.bookingCount > 0 })
        XCTAssertTrue(model.bookings.contains { $0.tags.map(\.name) == ["Auto", "Urlaub"] },
                      "the rental car carries two tags, in tag list order")
    }

    func testNewTagGoesOnTheRowsWithoutAReload() throws {
        let picked = try untagged(2)
        model.addTag(named: "  Steuer ", to: picked)
        XCTAssertNil(model.errorMessage)
        let steuer = try XCTUnwrap(model.tags.first { $0.name == "Steuer" })
        XCTAssertEqual(steuer.bookingCount, 2)
        XCTAssertFalse(steuer.colorHex.isEmpty, "a new tag gets a palette colour")
        for b in picked {
            XCTAssertEqual(try row(b.id).tags.map(\.name), ["Steuer"])
            XCTAssertEqual(try stored(b.id), ["Steuer"])
        }
    }

    func testKnownNameIsReusedWhateverTheCase() throws {
        let b = try untagged(1)[0]
        model.addTag(named: "auto", to: [b])
        XCTAssertEqual(model.tags.count, 3)
        XCTAssertEqual(try row(b.id).tags.map(\.name), ["Auto"])
    }

    func testToggleOnAMixedSelectionGivesItToAllThenTakesItFromAll() throws {
        let auto = try XCTUnwrap(model.tags.first { $0.name == "Auto" })
        let carrier = try XCTUnwrap(model.bookings.first { $0.tags.contains { $0.id == auto.id } })
        let other = try untagged(1)[0]
        let before = auto.bookingCount

        let usage = model.tagUsage(of: [carrier, other])
        XCTAssertEqual(usage.first { $0.tag.id == auto.id }?.all, false)

        model.toggleTag(auto.id, on: [carrier, other])
        XCTAssertTrue(try row(other.id).tags.contains { $0.id == auto.id })
        XCTAssertEqual(model.tags.first { $0.id == auto.id }?.bookingCount, before + 1)

        model.toggleTag(auto.id, on: [try row(carrier.id), try row(other.id)])
        XCTAssertFalse(try row(carrier.id).tags.contains { $0.id == auto.id })
        XCTAssertFalse(try row(other.id).tags.contains { $0.id == auto.id })
        XCTAssertEqual(try stored(other.id), [])
        XCTAssertEqual(model.tags.first { $0.id == auto.id }?.bookingCount, before - 1)
    }

    func testRemoveFromOneBooking() throws {
        let rental = try XCTUnwrap(model.bookings.first { $0.tags.count == 2 })
        let urlaub = try XCTUnwrap(rental.tags.first { $0.name == "Urlaub" })
        model.removeTag(urlaub.id, from: [rental.id])
        XCTAssertEqual(try row(rental.id).tags.map(\.name), ["Auto"])
        XCTAssertEqual(try stored(rental.id), ["Auto"])
    }

    func testEditTagsKeepsAMultipleSelection() throws {
        let picked = try untagged(2)
        model.selectedBookingID = picked[0].id
        model.selectedBookingIDs = Set(picked.map(\.id))
        model.editTags(for: picked[1])
        XCTAssertEqual(model.selectedBookingIDs, Set(picked.map(\.id)))
        XCTAssertEqual(model.pendingTagFocus, picked[1].id)
    }

    /// What Return in the tag field will do: the hint below the field says the same.
    func testEntryIntentMatchesTheCoreNameRules() throws {
        let urlaub = try XCTUnwrap(model.tags.first { $0.name == "Urlaub" })
        let tags = model.tags
        XCTAssertEqual(AppModel.tagEntryIntent("   ", tags: tags, carried: []), .none)
        XCTAssertEqual(AppModel.tagEntryIntent("  Urlaub   2027 ", tags: tags, carried: []), .create("Urlaub 2027"))
        XCTAssertEqual(AppModel.tagEntryIntent("URLAUB", tags: tags, carried: []), .add(urlaub.id, "Urlaub"))
        XCTAssertEqual(AppModel.tagEntryIntent(" urlaub ", tags: tags, carried: [urlaub.id]), .already("Urlaub"))
        // look-alikes: a warning, Return still creates the new name
        let test1 = try XCTUnwrap(model.tag(named: "test-1"))
        let all = model.tags
        for typed in ["test 1", "Test_1", "TEST1", "tést.1"] {
            XCTAssertEqual(AppModel.tagEntryIntent(typed, tags: all, carried: []),
                           .similar(new: AppModel.cleanTagName(typed), existingID: test1.id, existing: "test-1"), typed)
        }
        XCTAssertEqual(AppModel.tagEntryIntent("test 2", tags: all, carried: []), .create("test 2"))
        XCTAssertEqual(AppModel.tagEntryIntent("Urlaub 2026", tags: all, carried: []), .create("Urlaub 2026"))
        XCTAssertEqual(AppModel.tagEntryIntent("Test-1", tags: all, carried: []), .add(test1.id, "test-1"),
                       "the same name (case aside) is the tag itself, not a look-alike")
        let limit = String(repeating: "ä", count: AppModel.maxTagNameLength)
        XCTAssertEqual(AppModel.tagEntryIntent(limit, tags: tags, carried: []), .create(limit))
        XCTAssertEqual(AppModel.tagEntryIntent(limit + "x", tags: tags, carried: []), .tooLong)
    }

    /// The Swift length check agrees with the core: 64 characters are accepted, 65 are not.
    func testLengthLimitIsTheCoresLimit() throws {
        let vault = try XCTUnwrap(model.vault)
        XCTAssertNoThrow(try vault.createTag(name: String(repeating: "é", count: AppModel.maxTagNameLength), colorHex: ""))
        XCTAssertThrowsError(try vault.createTag(name: String(repeating: "é", count: AppModel.maxTagNameLength + 1), colorHex: ""))
    }

    /// The expanded row (compact density, #542) lists the tags, hidden like personal data.
    func testInlineDetailsListTheTags() throws {
        let rental = try XCTUnwrap(model.bookings.first { $0.tags.count == 2 })
        let field = try XCTUnwrap(BookingInlineDetails.fields(for: rental).first { $0.id == "tags" })
        XCTAssertEqual(field.value, "Auto, Urlaub")
        XCTAssertEqual(field.redaction, .personal)
        let plain = try untagged(1)[0]
        XCTAssertNil(BookingInlineDetails.fields(for: plain).first { $0.id == "tags" })
    }
}
