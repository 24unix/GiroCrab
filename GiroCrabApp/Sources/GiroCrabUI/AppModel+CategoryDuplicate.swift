import Foundation
import GiroCrabCore

extension AppModel {
    /// "Duplizieren" of a category (#510): copies it with all its sub-categories
    /// (name, symbol, colour; no bookings, rules or budgets) next to the original.
    /// The copy of the top category is named "<name> Kopie". Returns the new id.
    @discardableResult
    func duplicateCategory(_ id: Int64) -> Int64? {
        guard let vault, let root = categories.first(where: { $0.id == id }) else { return nil }
        let children = Dictionary(grouping: categories.filter { $0.parentId != nil }, by: { $0.parentId! })
        var newRoot: Int64?
        runCore {
            func copy(_ c: GiroCrabCore.Category, under parent: Int64?, name: String, depth: Int) throws -> Int64 {
                let new = try vault.createCategory(name: name, parentId: parent, sfSymbol: c.sfSymbol, colorHex: c.colorHex)
                if depth < 16 {
                    for child in children[c.id] ?? [] {
                        _ = try copy(child, under: new, name: child.name, depth: depth + 1)
                    }
                }
                return new
            }
            let suffix = String(localized: "Kopie")
            newRoot = try copy(root, under: root.parentId, name: "\(root.name) \(suffix)", depth: 0)
        }
        reloadCategories()
        if let parent = root.parentId { expandedCategories.insert(parent) }
        return newRoot
    }
}
