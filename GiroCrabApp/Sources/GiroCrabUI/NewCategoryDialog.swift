import SwiftUI
import GiroCrabCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A pending category sheet: a new (top-level or sub-) category, or editing
/// an existing one (`editing` set).
struct NewCategoryRequest: Identifiable, Equatable {
    let id = UUID()
    var parent: Int64?
    /// The category to edit; nil = create a new one under `parent`.
    var editing: Int64? = nil
}

/// Create/edit sheet for a category: name, symbol and colour (#168), driven
/// by `model.newCategoryRequest`.
struct NewCategoryDialog: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .sheet(item: $model.newCategoryRequest) { request in
                CategoryEditorSheet(request: request).environment(model)
            }
    }
}

struct CategoryEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: NewCategoryRequest

    @State private var name = ""
    @State private var symbol = "tag.fill"
    @State private var colorHex = "#7A808A"
    /// nil = top-level category
    @State private var parent: Int64?
    /// The user picked a colour – a new parent then no longer passes its own.
    @State private var colorChosen = false

    private static let palette = accountColorPalette()
    private var editing: GiroCrabCore.Category? {
        request.editing.flatMap { id in model.categories.first { $0.id == id } }
    }
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The palette plus the category's own colour, if that is not in it.
    private var colors: [String] {
        Self.palette.contains(colorHex.uppercased()) ? Self.palette : [colorHex.uppercased()] + Self.palette
    }
    /// Possible parents: every category except the edited one and its own
    /// sub-categories (the core refuses such a loop too).
    private var parentCandidates: [GiroCrabCore.Category] {
        guard let own = request.editing else { return model.categories }
        let byID = Dictionary(model.categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func isOwnOrBelow(_ c: GiroCrabCore.Category) -> Bool {
            var cur: Int64? = c.id
            var guardCount = 0
            while let id = cur, guardCount < 64 {
                if id == own { return true }
                cur = byID[id]?.parentId
                guardCount += 1
            }
            return false
        }
        return model.categories.filter { !isOwnOrBelow($0) }
    }
    private var chosenColor: Binding<String> {
        Binding(get: { colorHex }, set: { colorHex = $0; colorChosen = true })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    SymbolPickerButton(selection: $symbol, tint: Color.readable(hex: colorHex))
                    LabeledContent("Farbe") {
                        HStack(alignment: .top, spacing: 10) {
                            ColorSwatches(colors: colors, selection: chosenColor)
                            // any other colour: the system colour well
                            ColorPicker("Eigene Farbe", selection: Binding(
                                get: { Color(hex: colorHex) },
                                set: { if let hex = $0.hexRGB { chosenColor.wrappedValue = hex } }
                            ), supportsOpacity: false)
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(width: 28, height: 22)
                            .help("Eigene Farbe")
                        }
                    }
                }
                Section {
                    // move a sub-category to another main category (or make
                    // it a main category itself)
                    Picker("Übergeordnete Kategorie", selection: $parent) {
                        Text("Keine (Hauptkategorie)").tag(Int64?.none)
                        Divider()
                        ForEach(parentCandidates) { c in
                            Text(verbatim: String(repeating: "\u{2003}", count: Int(c.depth)) + c.name)
                                .tag(Int64?.some(c.id))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Anlegen" : "Sichern") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(trimmed.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 380)
        #endif
        .onAppear(perform: load)
        .onChange(of: parent) { _, new in
            // a new sub-category takes its parent's colour until one is chosen
            if editing == nil, !colorChosen,
               let p = new.flatMap({ id in model.categories.first { $0.id == id } }) {
                colorHex = p.colorHex.uppercased()
            }
        }
    }

    private var title: LocalizedStringKey {
        if editing != nil { return "Kategorie bearbeiten" }
        return parent == nil ? "Neue Hauptkategorie" : "Neue Unterkategorie"
    }

    private func load() {
        if let c = editing {
            name = c.name
            symbol = c.sfSymbol.isEmpty ? "tag.fill" : c.sfSymbol
            colorHex = c.colorHex.uppercased()
            parent = c.parentId
            return
        }
        parent = request.parent
        if let p = request.parent.flatMap({ p in model.categories.first { $0.id == p } }) {
            // Sub-categories start with the parent's colour.
            colorHex = p.colorHex.uppercased()
        }
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        if let c = editing {
            model.updateCategory(c, name: trimmed, parent: parent, symbol: symbol, color: colorHex)
        } else {
            model.createCategory(name: trimmed, parent: parent, symbol: symbol, color: colorHex)
        }
        dismiss()
    }
}

/// A row of colour circles with a ring around the chosen one – the colour
/// row of Reminders' list editor.
struct ColorSwatches: View {
    let colors: [String]
    @Binding var selection: String

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 22), spacing: 6)], spacing: 6) {
            ForEach(colors, id: \.self) { hex in
                let chosen = hex == selection.uppercased()
                Button { selection = hex } label: {
                    Circle()
                        .fill(Color.readable(hex: hex))
                        .frame(width: 18, height: 18)
                        .padding(2)
                        .overlay(Circle().strokeBorder(chosen ? Color.primary.opacity(0.6) : .clear, lineWidth: 1.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(Text(AccountColorNames.names[hex] ?? LocalizedStringKey(hex)))
                .accessibilityLabel(Text(AccountColorNames.names[hex] ?? LocalizedStringKey(hex)))
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .frame(maxWidth: 200)
    }
}

extension Color {
    /// `#RRGGBB` in sRGB (nil if the colour can't be converted).
    var hexRGB: String? {
        #if os(macOS)
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let (r, g, b) = (c.redComponent, c.greenComponent, c.blueComponent)
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        #endif
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}

extension View {
    func newCategoryDialog() -> some View { modifier(NewCategoryDialog()) }
}
