import SwiftUI
import GiroCrabCore

/// Details use only the already loaded booking. Selecting a row never fetches
/// bank data or acquires the vault mutex to expand its presentation.
struct BookingInlineDetails: View {
    let booking: Booking
    @Environment(\.textScale) private var textScale

    struct Field: Identifiable {
        let id: String
        let title: String
        let value: String
        let redaction: ReportRedaction
    }

    static func fields(for booking: Booking) -> [Field] {
        var result: [Field] = []
        func add(_ id: String, _ title: String, _ raw: String, hides: ReportRedaction = .personal) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            result.append(Field(id: id, title: title, value: value, redaction: hides))
        }
        let title = booking.merchant.name.isEmpty ? booking.bookingText : booking.merchant.name
        if booking.counterparty != title {
            add("counterparty", String(localized: "Gegenpartei"), booking.counterparty)
        }
        add("category", String(localized: "Kategorie"),
            booking.categoryPath.isEmpty ? booking.categoryName : booking.categoryPath, hides: .labels)
        add("note", String(localized: "Notiz"), booking.note)
        let transactionType = booking.paymentMethod.isEmpty ? booking.bookingText : booking.paymentMethod
        add("type", String(localized: "Umsatzart"), transactionType)
        if booking.bookingText != title,
           booking.bookingText.caseInsensitiveCompare(transactionType) != .orderedSame,
           booking.bookingText != booking.cleanPurpose {
            add("bookingText", String(localized: "Buchungstext"), booking.bookingText)
        }
        let references = sepaFields(in: booking.purpose)
        add("reference", String(localized: "Referenz"), references["EREF"] ?? "")
        add("customerReference", String(localized: "Kundenreferenz"), references["KREF"] ?? "")
        add("mandate", String(localized: "Mandatsreferenz"), references["MREF"] ?? "")
        add("creditor", String(localized: "Gläubiger-ID"), references["CRED"] ?? "")
        if let ref = AmazonOrderRef.parse(purpose: booking.purpose, merchantDomain: booking.merchantDomain,
                                         bookingText: booking.bookingText) {
            add("order", String(localized: "Bestellnummer"), ref.code)
        }
        if !booking.valueDate.isEmpty {
            add("valueDate", String(localized: "Wertstellung"), DateText.medium(booking.valueDate), hides: [])
        }
        add("account", String(localized: "Konto"), booking.accountName)
        add("iban", String(localized: "IBAN Gegenkonto"), formatIBAN(booking.counterpartyIban))
        return result
    }

    // SEPA tags are already present in the source text. Keep values with spaces
    // intact, and stop at the next tag (including SVWZ, which is narrative text).
    private static let tagPattern = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9])[A-Z]{3,4}\+"#)

    /// Preserve original narrative, line breaks and card/date information.
    /// Only move explicitly tagged references to the labelled fields below.
    static func fullPurpose(for booking: Booking) -> String {
        let raw = booking.purpose.isEmpty ? booking.cleanPurpose : booking.purpose
        let text = raw as NSString
        let matches = tagPattern.matches(in: raw, range: NSRange(location: 0, length: text.length))
        let narrative = NSMutableString(string: raw)
        for index in matches.indices.reversed() {
            let match = matches[index]
            let tag = String(text.substring(with: match.range).dropLast())
            if ["EREF", "KREF", "MREF", "CRED"].contains(tag) {
                let end = index + 1 < matches.count ? matches[index + 1].range.location : text.length
                narrative.deleteCharacters(in: NSRange(location: match.range.location, length: end - match.range.location))
            } else if tag == "SVWZ" {
                narrative.deleteCharacters(in: match.range)
            }
        }
        let value = (narrative as String).trimmingCharacters(in: .whitespacesAndNewlines)
        let title = booking.merchant.name.isEmpty ? booking.bookingText : booking.merchant.name
        return value == title ? "" : value
    }

    static func sepaFields(in purpose: String) -> [String: String] {
        let text = purpose as NSString
        let matches = tagPattern.matches(in: purpose, range: NSRange(location: 0, length: text.length))
        var fields: [String: String] = [:]
        for (index, match) in matches.enumerated() {
            let tag = String(text.substring(with: match.range).dropLast())
            guard ["EREF", "KREF", "MREF", "CRED"].contains(tag) else { continue }
            let start = NSMaxRange(match.range)
            let end = index + 1 < matches.count ? matches[index + 1].range.location : text.length
            let value = text.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, !["NOTPROVIDED", "NONREF"].contains(value.uppercased()) {
                fields[tag] = value
            }
        }
        return fields
    }

    var body: some View {
        BookingDetailGrid(minimumColumnWidth: 240 * textScale, horizontalSpacing: 20 * textScale, verticalSpacing: 4 * textScale) {
            ForEach(Self.fields(for: booking)) { field in
                Text("\(Text(verbatim: field.title).bold()): \(Text(verbatim: field.value))")
                    .appFont(.callout)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .sensitive(field.redaction)
            }
        }
    }
}

/// Equal-width columns keep labels aligned across rows. Fewer columns at
/// narrow widths allow every value to wrap without truncation.
private struct BookingDetailGrid: Layout {
    var minimumColumnWidth: CGFloat
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    private func arrangement(width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], sizes: [CGSize], height: CGFloat) {
        var origins: [CGPoint] = []
        var sizes: [CGSize] = []
        let columns = max(1, Int((width + horizontalSpacing) / (minimumColumnWidth + horizontalSpacing)))
        let columnWidth = max(0, (width - CGFloat(columns - 1) * horizontalSpacing) / CGFloat(columns))
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let column = index % columns
            if column == 0, index > 0 {
                y += lineHeight + verticalSpacing
                lineHeight = 0
            }
            let size = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
            origins.append(CGPoint(x: CGFloat(column) * (columnWidth + horizontalSpacing), y: y))
            sizes.append(size)
            lineHeight = max(lineHeight, size.height)
        }
        return (origins, sizes, y + lineHeight)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(0, proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0)
        return CGSize(width: width, height: arrangement(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let origin = result.origins[index]
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                          anchor: .topLeading, proposal: ProposedViewSize(result.sizes[index]))
        }
    }
}
