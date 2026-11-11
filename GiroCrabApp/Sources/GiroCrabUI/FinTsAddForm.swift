import SwiftUI
import GiroCrabCore

/// Preset picker + manual BLZ / FinTS URL for "Andere FinTS-Bank".
/// Any FinTS 3.0 PIN/TAN bank works: pick a preset, search for it, or type an
/// 8-digit BLZ (or paste a German IBAN) – name and FinTS URL are then filled in
/// from the built-in bank directory. The URL stays editable for custom banks.
struct FinTsAddForm: View {
    @Environment(AppModel.self) private var model
    /// Bank chosen in the search picker (pre-fills BLZ, name and URL).
    var prefill: BankSearchResult? = nil
    var onAdded: () -> Void = {}

    @State private var presets = fintsPresets()
    @State private var presetID = "custom"
    @State private var blz = ""
    @State private var url = ""
    @State private var bankName = ""
    @State private var login = ""
    @State private var tanMedium = ""
    /// Bank found in the directory for the current BLZ.
    @State private var found: FinTsBankInfo?
    /// The URL we filled in ourselves; typing anything else marks it as user-edited.
    @State private var autoURL = ""
    @State private var urlEdited = false

    private var preset: FinTsPreset? { presets.first { $0.id == presetID } }
    private var blzValid: Bool { blz.count == 8 && blz.allSatisfy(\.isASCII) && blz.allSatisfy(\.isNumber) }
    private var urlValid: Bool { url.hasPrefix("https://") && url.count > 9 && !url.contains(where: \.isWhitespace) }
    /// Banks that use BestSign / need a TAN medium name and (Postbank) the Postbank ID.
    private var bankName_lc: String { (found?.name ?? bankName).lowercased() }
    private var isPostbank: Bool { bankName_lc.contains("postbank") }
    private var needsMediumHint: Bool {
        isPostbank || bankName_lc.contains("deutsche bank") || bankName_lc.contains("norisbank")
    }
    private var canAdd: Bool { blzValid && urlValid && !login.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Picker("Bank", selection: $presetID) {
            ForEach(presets, id: \.id) { Text($0.name).tag($0.id) }
        }
        .onChange(of: presetID) { _, _ in
            guard let p = preset else { return }
            bankName = p.id == "custom" ? "" : p.name
            urlEdited = false
            autoURL = p.url
            url = p.url
            blz = p.blz
            lookup()
        }
        TextField("BLZ (8 Ziffern) oder IBAN", text: $blz)
            .autocorrectionDisabled()
            .onChange(of: blz) { _, _ in
                // a pasted German IBAN becomes its BLZ (characters 5–12)
                if let b = blzFromBankInput(input: blz), b != blz { blz = b; return }
                lookup()
            }
        if let f = found {
            Label(f.name, systemImage: "checkmark.seal")
                .font(.caption).foregroundStyle(.secondary)
        } else if blzValid {
            Label("BLZ nicht im Verzeichnis – bitte FinTS-URL selbst eintragen.", systemImage: "questionmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
        TextField("FinTS-URL (https://…)", text: $url)
            .autocorrectionDisabled()
            .onChange(of: url) { _, new in if new != autoURL { urlEdited = true } }
        TextField("Anmeldename / VR-NetKey / Kontonummer", text: $login).autocorrectionDisabled()
        TextField("TAN-Medium / Gerätename (optional, z. B. bei Postbank BestSign)", text: $tanMedium)
            .autocorrectionDisabled()
        if isPostbank {
            Label("Postbank: Als Anmeldename die Postbank ID verwenden (nicht die Kontonummer).", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
        if needsMediumHint {
            Text("Fordert die Bank ein TAN-Medium (Fehler 9210), tragen Sie hier den Gerätenamen aus der BestSign-/App-Verwaltung ein, z. B. SO:Gerätename.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let n = preset?.note, !n.isEmpty {
            Text(n).font(.caption).foregroundStyle(.secondary)
        }
        if (!blz.isEmpty && !blzValid) || (!url.isEmpty && !urlValid) {
            Label("BLZ: genau 8 Ziffern · URL: muss mit https:// beginnen", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
        Button("Bank hinzufügen") {
            let name = bankName.trimmingCharacters(in: .whitespaces)
            model.addFinTsConnection(name: name.isEmpty ? "FinTS-Bank \(blz)" : name, blz: blz, url: url, login: login, tanMedium: tanMedium)
            login = ""
            tanMedium = ""
            onAdded()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canAdd)
        .onAppear { apply(prefill) }
        .onChange(of: prefill?.id) { _, _ in apply(prefill) }
    }

    private func apply(_ r: BankSearchResult?) {
        guard let r, r.mode == .finTs else { return }
        presetID = "custom"
        bankName = r.name
        autoURL = r.url
        urlEdited = false
        url = r.url
        blz = r.blz
        lookup()
    }

    /// Fills in name and URL from the directory once a full BLZ is typed.
    private func lookup() {
        guard blzValid, let info = lookupFintsBankByBlz(blz: blz) else {
            // BLZ no longer matches: drop what we filled in ourselves
            if found != nil {
                found = nil
                if !urlEdited, url == autoURL { url = ""; autoURL = "" }
            }
            return
        }
        found = info
        if bankName.isEmpty || preset?.name == bankName || presetID == "custom" { bankName = info.name }
        if !urlEdited || url.isEmpty {
            autoURL = info.url
            url = info.url
            urlEdited = false
        }
    }
}
