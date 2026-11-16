import SwiftUI
import GiroCrabCore

/// Bookings dragged from the list onto a sidebar category (#366, macOS only:
/// iOS has no drag pasteboard to tell them from accounts). A plain string like
/// `GroupDrag`, so the sidebar's drop zones receive it. Every other `String`
/// or `URL` drop target sees it too and must ignore it.
enum BookingDrag {
    static let prefix = "girocrab-bookings:"

    static func payload(_ ids: [Int64]) -> String {
        prefix + ids.map(String.init).joined(separator: ",")
    }

    static func ids(_ s: String) -> [Int64] {
        guard s.hasPrefix(prefix) else { return [] }
        return s.dropFirst(prefix.count).split(separator: ",").compactMap { Int64($0) }
    }

    /// Whether the drag in progress carries bookings.
    static var isDragged: Bool { GroupDrag.draggedString?.hasPrefix(prefix) == true }
}

/// "Kategorie" of the row menu (#366): the category tree to pick from, the
/// search sheet and removal. Acts on the multiple selection when the row is
/// part of it. A view of its own, so the selection and the categories stay out
/// of the day card's dependencies.
struct CategoryAssignMenu: View {
    @Environment(AppModel.self) private var model
    let booking: Booking

    var body: some View {
        let targets = model.categorizeTargets(for: booking)
        let assigned = Set(targets.map(\.categoryId))
        Menu("Kategorie", systemImage: "tag") {
            CategoryMenuItems(nodes: model.categoryTree, current: assigned.count == 1 ? assigned.first ?? nil : nil) {
                model.setCategory($0, for: targets)
            }
            Divider()
            Button(targets.count > 1 ? "\(targets.count) Buchungen kategorisieren …" : "Kategorisieren …",
                   systemImage: "magnifyingglass") {
                if !model.selectedBookingIDs.contains(booking.id) { model.selectedBookingID = booking.id }
                model.showCategorizer = true
            }
            Button("Kategorie entfernen", systemImage: "tag.slash") { model.setCategory(nil, for: targets) }
                .disabled(assigned == [nil])
        }
    }
}

/// The category tree as nested menus: a category with sub-categories opens
/// them, a leaf is assigned (as in the inspector's grid). `current` is checked;
/// picking it again changes nothing (it would turn a rule's category manual).
private struct CategoryMenuItems: View {
    let nodes: [CategoryNode]
    let current: Int64?
    let pick: (Int64) -> Void

    var body: some View {
        ForEach(nodes) { node in
            let label = Label(node.category.name, systemImage: node.category.sfSymbol)
            if let kids = node.children {
                Menu {
                    CategoryMenuItems(nodes: kids, current: current, pick: pick)
                } label: { label }
            } else {
                Toggle(isOn: Binding(get: { node.id == current }, set: { if $0 { pick(node.id) } })) { label }
            }
        }
    }
}
