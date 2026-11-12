import SwiftUI
import GiroCrabCore

/// A pending "new category" prompt; `parent == nil` creates a top-level category.
struct NewCategoryRequest: Identifiable, Equatable {
    let id = UUID()
    var parent: Int64?
}

/// Name prompt for a new (top-level or sub-) category, driven by `model.newCategoryRequest`.
struct NewCategoryDialog: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var name = ""

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .alert(
                model.newCategoryRequest?.parent == nil ? "Neue Hauptkategorie" : "Neue Unterkategorie",
                isPresented: Binding(get: { model.newCategoryRequest != nil }, set: { if !$0 { model.newCategoryRequest = nil } }),
                presenting: model.newCategoryRequest
            ) { request in
                TextField("Name", text: $name)
                Button("Anlegen") { create(request) }
                Button("Abbrechen", role: .cancel) { name = "" }
            } message: { request in
                if let path = model.categoryPath(request.parent) {
                    Text("Wird angelegt unter „\(path)“.")
                }
            }
    }

    private func create(_ request: NewCategoryRequest) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        name = ""
        guard !trimmed.isEmpty else { return }
        // Sub-categories inherit the parent's colour.
        let color = request.parent.flatMap { p in model.categories.first { $0.id == p }?.colorHex } ?? "#7A808A"
        model.createCategory(name: trimmed, parent: request.parent, symbol: "tag.fill", color: color)
    }
}

extension View {
    func newCategoryDialog() -> some View { modifier(NewCategoryDialog()) }
}
