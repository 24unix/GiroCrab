import XCTest
import SwiftUI
@testable import GiroCrabUI

@MainActor
final class BookingDensityTests: XCTestCase {
    func testPreferenceDefaultsAndPersistsAcrossReaders() throws {
        let domain = "BookingDensityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preference = AppStorage(wrappedValue: BookingDensity.standard, BookingDensity.defaultsKey, store: defaults)
        XCTAssertEqual(preference.wrappedValue, .standard)
        for density in BookingDensity.allCases {
            preference.wrappedValue = density
            let reopened = AppStorage(wrappedValue: BookingDensity.standard, BookingDensity.defaultsKey,
                                      store: try XCTUnwrap(UserDefaults(suiteName: domain)))
            XCTAssertEqual(reopened.wrappedValue, density)
        }
        defaults.set("unknown-future-value", forKey: BookingDensity.defaultsKey)
        let fallback = AppStorage(wrappedValue: BookingDensity.standard, BookingDensity.defaultsKey, store: defaults)
        XCTAssertEqual(fallback.wrappedValue, .standard)
    }

    func testPurposeOmitsEmptyTextAndDuplicateTitle() throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        var booking = try XCTUnwrap(model.bookings.first)
        booking.cleanPurpose = "  \n "
        booking.purpose = " "
        XCTAssertEqual(BookingDensity.spacious.purpose(for: booking), "")
        booking.cleanPurpose = booking.merchant.name.isEmpty ? booking.bookingText : booking.merchant.name
        XCTAssertEqual(BookingDensity.standard.purpose(for: booking), "")
        booking.cleanPurpose = "  Rechnung für erfundene Gartenarbeiten  "
        XCTAssertEqual(BookingDensity.spacious.purpose(for: booking), "Rechnung für erfundene Gartenarbeiten")
    }

    func testPurposeUsesUpstreamFallbackAndDuplicateNormalization() throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        var booking = try XCTUnwrap(model.bookings.first)
        booking.merchant.name = "Fiktive Gartenwerkstatt"
        booking.cleanPurpose = ""
        booking.purpose = "Rechnung DEMO-42\nfür Pflanzen"
        XCTAssertEqual(BookingDensity.compact.purpose(for: booking), "Rechnung DEMO-42 für Pflanzen")
        booking.cleanPurpose = "FIKTIVE-GARTENWERKSTATT"
        XCTAssertEqual(BookingDensity.standard.purpose(for: booking), "")
    }

    func testOnlyActiveCompactRowExpandsWhileStandardStaysUnchanged() {
        XCTAssertFalse(BookingDensity.compact.showsDetails(isActive: false))
        XCTAssertTrue(BookingDensity.compact.showsDetails(isActive: true))
        XCTAssertFalse(BookingDensity.standard.showsDetails(isActive: true))
        XCTAssertTrue(BookingDensity.spacious.showsDetails(isActive: false))
    }

    func testReferenceValuesKeepSpacesAndIgnoreMissingReferences() {
        let fields = BookingInlineDetails.sepaFields(in: "SVWZ+Erfundene Pflanzen 🌱 EREF+DEMO 123 MREF+Mandat Beispiel CRED+DE00ZZZDEMO KREF+NOTPROVIDED")
        XCTAssertEqual(fields["EREF"], "DEMO 123")
        XCTAssertEqual(fields["MREF"], "Mandat Beispiel")
        XCTAssertEqual(fields["CRED"], "DE00ZZZDEMO")
        XCTAssertNil(fields["KREF"])
        XCTAssertTrue(BookingInlineDetails.sepaFields(in: "Eine normale Buchung ohne Referenz").isEmpty)
    }

    func testExpandedFieldsIncludeAllAvailableDetailsWithoutDuplicateBookingText() throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        var booking = try XCTUnwrap(model.bookings.first)
        booking.purpose = "EREF+DEMO-123 MREF+DEMO-MANDAT SVWZ+Erfundene Rechnung"
        booking.cleanPurpose = "Erfundene Rechnung"
        booking.note = "Vollständige fiktive Notiz"
        booking.paymentMethod = "Lastschrift"
        booking.bookingText = "Lastschrift"
        booking.valueDate = booking.bookingDate
        booking.counterpartyIban = ""
        let fields = BookingInlineDetails.fields(for: booking)
        XCTAssertEqual(fields.first { $0.id == "reference" }?.value, "DEMO-123")
        XCTAssertEqual(fields.first { $0.id == "mandate" }?.value, "DEMO-MANDAT")
        XCTAssertEqual(fields.first { $0.id == "note" }?.value, booking.note)
        XCTAssertNotNil(fields.first { $0.id == "valueDate" }, "Value date is useful even when equal to the booking date")
        XCTAssertNotNil(fields.first { $0.id == "type" })
        XCTAssertNil(fields.first { $0.id == "bookingText" })
        XCTAssertNil(fields.first { $0.id == "iban" })
        XCTAssertTrue(fields.allSatisfy { !$0.value.isEmpty })
    }

    func testFullPurposePreservesOriginalCardTextAndMovesOnlyTaggedReferences() throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        var booking = try XCTUnwrap(model.bookings.first)
        booking.purpose = "EREF+DEMO 123 SVWZ+Erfundener Einkauf\nDebitk.1 2026-11-02 PP.DEMO.PP MREF+FIKTIVES MANDAT"
        booking.cleanPurpose = "Erfundener Einkauf"
        XCTAssertEqual(BookingInlineDetails.fullPurpose(for: booking), "Erfundener Einkauf\nDebitk.1 2026-11-02 PP.DEMO.PP")
        XCTAssertEqual(BookingDensity.standard.purpose(for: booking), "Erfundener Einkauf")
    }

    #if os(macOS)
    /// Exercises real SwiftUI layout with narrow widths, long text and large type.
    /// Optional local QA images contain only the fictional fixture below.
    func testNarrowRowsGrowForDetailsAndLargeText() throws {
        let domain = "BookingDensityRendering.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        var booking = try XCTUnwrap(model.bookings.first)
        model.selectedBookingID = nil
        booking.merchant.name = "Fiktive Gartenwerkstatt am langen Beispielweg"
        booking.counterparty = booking.merchant.name
        booking.categoryName = "Gartenbedarf"
        booking.categoryPath = "Wohnen › Gartenbedarf"
        booking.categorySymbol = "leaf"
        booking.categoryColorHex = "#228855"
        booking.cleanPurpose = "Rechnung DEMO-2026-12345 für Gartenarbeiten und die Lieferung erfundener Pflanzen an die Beispielstraße. Ausschließlich fiktive Testdaten."
        booking.note = "Fiktive Notiz: Material und Arbeitszeit getrennt auf dem Beleg prüfen."
        booking.purpose = "EREF+DEMO-2026-12345 MREF+FIKTIVES MANDAT SVWZ+" + booking.cleanPurpose
        booking.paymentMethod = "Lastschrift"
        booking.valueDate = "2026-11-02"
        booking.amountCents = -123456789
        var expandedHeights: [Double: Int] = [:]
        for width in [360.0, 600.0, 1000.0] {
            for size in [AppTextSize.standard, .larger] {
                var heights: [Int] = []
                for density in BookingDensity.allCases {
                    defaults.set(density.rawValue, forKey: BookingDensity.defaultsKey)
                    let row = BookingRow(booking: booking)
                        .environment(model).listSettingsEnvironment().defaultAppStorage(defaults)
                        .appTextSize(size).frame(width: width)
                    let renderer = ImageRenderer(content: row)
                    let image = try XCTUnwrap(renderer.cgImage)
                    XCTAssertEqual(image.width, Int(width))
                    heights.append(image.height)
                    if let directory = ProcessInfo.processInfo.environment["GIROCRAB_DENSITY_SHOTS"] {
                        let bitmap = NSBitmapImageRep(cgImage: image)
                        let url = URL(fileURLWithPath: directory).appendingPathComponent("row-\(density.rawValue)-\(Int(width))-\(size.rawValue).png")
                        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
                    }
                }
                XCTAssertLessThan(heights[0], heights[2], "Collapsed compact rows must stay shorter than full details")
                XCTAssertLessThan(heights[1], heights[2], "Spacious must have room for additional content")
                defaults.set(BookingDensity.compact.rawValue, forKey: BookingDensity.defaultsKey)
                model.selectedBookingID = booking.id
                let expanded = ImageRenderer(content: BookingRow(booking: booking)
                    .environment(model).listSettingsEnvironment().defaultAppStorage(defaults).appTextSize(size).frame(width: width))
                let image = try XCTUnwrap(expanded.cgImage)
                if size == .standard { expandedHeights[width] = image.height }
                XCTAssertGreaterThanOrEqual(image.height, heights[2], "Compact details also reserve room for the date column")
                let collapsed = ImageRenderer(content: BookingRow(booking: booking, compactDetailsCollapsed: true)
                    .environment(model).listSettingsEnvironment().defaultAppStorage(defaults).appTextSize(size).frame(width: width))
                XCTAssertEqual(try XCTUnwrap(collapsed.cgImage).height, heights[0],
                               "Closing details keeps selection but restores the single-line height")
                if let directory = ProcessInfo.processInfo.environment["GIROCRAB_DENSITY_SHOTS"] {
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    try bitmap.representation(using: .png, properties: [:])?.write(to:
                        URL(fileURLWithPath: directory).appendingPathComponent("row-selected-compact-\(Int(width))-\(size.rawValue).png"))
                }
                model.selectedBookingID = nil
            }
        }
        XCTAssertLessThan(try XCTUnwrap(expandedHeights[1000]), try XCTUnwrap(expandedHeights[360]),
                          "Wide details use fewer lines while preserving all fields")
    }
    #endif
}
