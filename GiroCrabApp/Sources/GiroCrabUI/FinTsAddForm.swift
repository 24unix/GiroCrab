import SwiftUI
import GiroCrabCore

/// Preset picker + manual BLZ / FinTS URL for "Andere FinTS-Bank".
/// Any FinTS 3.0 PIN/TAN bank works: pick a preset or type 8-digit BLZ and https URL.
struct FinTsAddForm: View {
    @Environment(AppModel.self) private var model
    @State private var presets = fintsPresets()
    @State private var presetID = "custom"
    @State private var blz = ""
    @State private var url = ""
    @State private var login = ""

    private var preset: FinTsPreset? { presets.first { $0.id == presetID } }
    private var blzValid: Bool { blz.count == 8 && blz.allSatisfy(\.isASCII) && blz.allSatisfy(\.isNumber) }
    private var urlValid: Bool { url.hasPrefix("https://") && url.count > 9 && !url.contains(where: \.isWhitespace) }
    private var canAdd: Bool { blzValid && urlValid && !login.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Picker("Bank", selection: $presetID) {
            ForEach(presets, id: \.id) { Text($0.name).tag($0.id) }
        }
        .onChange(of: presetID) { _, _ in
            if let p = preset { blz = p.blz; url = p.url }
        }
        TextField("BLZ (8 Ziffern)", text: $blz).autocorrectionDisabled()
        TextField("FinTS-URL (https://…)", text: $url).autocorrectionDisabled()
        TextField("Anmeldename / VR-NetKey / Kontonummer", text: $login).autocorrectionDisabled()
        if let n = preset?.note, !n.isEmpty {
            Text(n).font(.caption).foregroundStyle(.secondary)
        }
        if (!blz.isEmpty && !blzValid) || (!url.isEmpty && !urlValid) {
            Label("BLZ: genau 8 Ziffern · URL: muss mit https:// beginnen", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
        Button("Bank hinzufügen") {
            model.addFinTsConnection(name: (preset?.id ?? "custom") == "custom" ? "FinTS-Bank \(blz)" : (preset?.name ?? ""), blz: blz, url: url, login: login)
            login = ""
        }
        .disabled(!canAdd)
    }
}
