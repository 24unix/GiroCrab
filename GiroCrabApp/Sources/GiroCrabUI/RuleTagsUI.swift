import SwiftUI
import GiroCrabCore

/// The tags a rule adds to every booking it matches (#580): chips with ✕, a menu of
/// the other tags and „Neuer Tag …“. A rule only ever adds tags, never removes one.
struct RuleTagsField: View {
    @Environment(AppModel.self) private var model
    @Binding var tagIds: [Int64]
    @State private var creating = false
    @State private var newName = ""

    private var chosen: [GiroCrabCore.Tag] {
        model.tags.filter { tagIds.contains($0.id) }
    }

    private var available: [GiroCrabCore.Tag] {
        model.tags.filter { !tagIds.contains($0.id) }
    }

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 6) {
                if !chosen.isEmpty {
                    TagFlow {
                        ForEach(chosen, id: \.id) { t in
                            TagChip(name: t.name, colorHex: t.colorHex, onRemove: {
                                tagIds.removeAll { $0 == t.id }
                            })
                        }
                    }
                }
                Menu {
                    ForEach(available, id: \.id) { t in
                        Button(t.name) { tagIds.append(t.id) }
                    }
                    if !available.isEmpty { Divider() }
                    Button("Neuer Tag …") { creating = true }
                } label: {
                    Label("Tag hinzufügen", systemImage: "plus")
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                #endif
                .fixedSize()
                .help("Diese Tags bekommt jede passende Buchung")
            }
        } label: {
            Text("Tags")
        }
        .alert("Neuer Tag", isPresented: $creating) {
            TextField("Name", text: $newName)
            Button("Anlegen") {
                if let t = model.tag(named: newName), !tagIds.contains(t.id) { tagIds.append(t.id) }
                newName = ""
            }
            Button("Abbrechen", role: .cancel) { newName = "" }
        }
    }
}
