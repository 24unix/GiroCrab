import SwiftUI

/// One card of the booking inspector (right-hand column) that the user can move or hide (#448).
/// The case order is the standard layout: the merchant history, whose stats load asynchronously
/// and grow the card, comes after the interactive category and document cards (#492).
enum InspectorSection: String, CaseIterable, Identifiable, Sendable {
    case receipt, note, salary, recurring, categories, documents, merchantHistory, rawData

    var id: String { rawValue }

    /// Name shown in the edit mode and in accessibility labels.
    var title: LocalizedStringResource {
        switch self {
        case .receipt: "Buchung"
        case .note: "Notiz"
        case .salary: "Gehalt / Rente"
        case .recurring: "Wiederkehrend"
        case .merchantHistory: "Händler-Historie"
        case .categories: "Kategorie"
        case .documents: "Belege & Abrechnungen"
        case .rawData: "SEPA & Bank-Rohdaten"
        }
    }

    var systemImage: String {
        switch self {
        case .receipt: "doc.text"
        case .note: "note.text"
        case .salary: "briefcase"
        case .recurring: "repeat"
        case .merchantHistory: "clock.arrow.circlepath"
        case .categories: "tag"
        case .documents: "paperclip"
        case .rawData: "doc.plaintext"
        }
    }

    /// Payload of a card being dragged in the edit mode; the prefix keeps foreign text drops out.
    var dragPayload: String { InspectorSection.dragPrefix + rawValue }
    static let dragPrefix = "girocrab.inspector-section:"

    init?(dragPayload: String) {
        guard dragPayload.hasPrefix(Self.dragPrefix) else { return nil }
        self.init(rawValue: String(dragPayload.dropFirst(Self.dragPrefix.count)))
    }
}

/// Order and visibility of the inspector cards, persisted per device in `UserDefaults` (#448).
/// Layout only, no vault data.
struct InspectorLayout: Equatable, Sendable {
    /// Every section exactly once; visible ones first, then the hidden ones.
    private(set) var order: [InspectorSection]
    private(set) var hidden: Set<InspectorSection>

    static let defaultsKey = "inspectorLayout"
    static let standard = InspectorLayout(order: InspectorSection.allCases, hidden: [])

    init(order: [InspectorSection], hidden: Set<InspectorSection>) {
        var seen = Set<InspectorSection>()
        var cleaned = order.filter { seen.insert($0).inserted }
        // Sections added in a later version (or lost in a broken value) show up at the end.
        cleaned += InspectorSection.allCases.filter { !seen.contains($0) }
        self.hidden = hidden
        self.order = cleaned.filter { !hidden.contains($0) } + cleaned.filter { hidden.contains($0) }
    }

    var visible: [InspectorSection] { order.filter { !hidden.contains($0) } }
    var hiddenSections: [InspectorSection] { order.filter { hidden.contains($0) } }
    var isStandard: Bool { self == .standard }

    /// Puts `section` at `index` of the visible list (0 = top, `visible.count` = bottom); shows it if it was hidden.
    mutating func move(_ section: InspectorSection, toVisibleIndex index: Int) {
        var shown = visible.filter { $0 != section }
        shown.insert(section, at: min(max(index, 0), shown.count))
        hidden.remove(section)
        order = shown + hiddenSections
    }

    /// Drop of `section` into `gap` of the visible list as it is drawn while dragging, i.e. still
    /// containing `section` itself (gap 0 = above the first card, `visible.count` = below the last).
    mutating func insert(_ section: InspectorSection, atGap gap: Int) {
        var index = gap
        if let current = visible.firstIndex(of: section), current < gap { index -= 1 }
        move(section, toVisibleIndex: index)
    }

    /// Hides `section`; it becomes the last of the hidden ones.
    mutating func hide(_ section: InspectorSection) {
        guard !hidden.contains(section) else { return }
        hidden.insert(section)
        order = visible + hiddenSections.filter { $0 != section } + [section]
    }

    /// Shows a hidden `section` again at the bottom of the visible list.
    mutating func show(_ section: InspectorSection) {
        guard hidden.contains(section) else { return }
        move(section, toVisibleIndex: visible.count)
    }

    // MARK: Persistence

    /// `"receipt,note,-salary"`: the order, hidden sections prefixed with `-`.
    var storageValue: String {
        order.map { hidden.contains($0) ? "-\($0.rawValue)" : $0.rawValue }.joined(separator: ",")
    }

    /// Unknown names are skipped; an empty or unreadable value gives the standard layout.
    init(storageValue: String) {
        var order: [InspectorSection] = []
        var hidden = Set<InspectorSection>()
        for token in storageValue.split(separator: ",") {
            let isHidden = token.hasPrefix("-")
            guard let section = InspectorSection(rawValue: String(isHidden ? token.dropFirst() : token)) else { continue }
            order.append(section)
            if isHidden { hidden.insert(section) }
        }
        self.init(order: order, hidden: hidden)
    }
}
