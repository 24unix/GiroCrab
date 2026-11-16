import SwiftUI
import UniformTypeIdentifiers
import GiroCrabCore

/// Imports a copy into the encrypted vault; the source file stays untouched.
struct Rah10AddForm: View {
    @Environment(AppModel.self) private var model
    var onAdded: () -> Void
    var submit: AddBankSubmit
    @State private var picking = false
    @State private var bytes = Data()
    @State private var fileName = ""
    @State private var name = "Commerzbank (RAH-10)"
    @State private var password = ""
    @State private var busy = false
    @State private var fileError: String?
    @State private var info: Rah10KeyfileInfo?
    @State private var candidates: [Rah10BankKeyCandidate] = []
    @State private var expected: [String: String] = [:]

    private func normalized(_ value: String) -> String {
        value.filter { !$0.isWhitespace && $0 != ":" }.uppercased()
    }

    private var ready: Bool {
        guard !bytes.isEmpty, !password.isEmpty, !busy, let info else { return false }
        return !info.needsBankKeys || (candidates.count == 2 && candidates.allSatisfy {
            normalized(expected[$0.keyType] ?? "") == $0.fingerprint
        })
    }

    var body: some View {
        Section {
            Button { picking = true } label: {
                Label(fileName.isEmpty ? "HBCI-Schlüsseldatei auswählen" : fileName, systemImage: "doc.badge.key")
                    .sensitive()
            }
            TextField("Anzeigename", text: $name).sensitive()
            SecureField("Passwort der Schlüsseldatei", text: $password).sensitive()
            Button("Datei prüfen", action: inspectFile)
                .disabled(bytes.isEmpty || password.isEmpty || busy)
            if let info {
                LabeledContent("Bankleitzahl", value: info.blz)
                Label("Passwort und Schlüsseldatei geprüft", systemImage: "checkmark.shield")
                if info.needsBankKeys {
                    Button("Öffentliche Bankschlüssel abrufen", action: fetchKeys)
                        .disabled(busy)
                }
            }
            if let fileError { Text(fileError).foregroundStyle(.red) }
            if busy { ProgressView("Einrichtung läuft …") }
        } header: {
            Text("Schlüsseldatei").appSectionHeader()
        } footer: {
            Text("GiroCrab übernimmt eine Kopie in den verschlüsselten Tresor. Die Originaldatei bleibt unverändert. Unterstützt zunächst Konto-, Salden- und Umsatzabrufe mit bestehenden Commerzbank-Zugängen. Verwenden Sie denselben Schlüssel nicht parallel in anderer Bankingsoftware. GiroCrab reserviert pro Abruf 10.000 Signaturzähler; ungenutzte Werte bleiben verbraucht und die Originaldatei behält ihren alten Zähler. Dadurch kann es bei paralleler Nutzung zu Zählerkonflikten kommen.")
                .appFont(.caption)
        }
        .disabled(busy)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            busy = true
            resetInspection()
            Task {
                defer { busy = false }
                do {
                    let data = try await Task.detached { try Rah10KeyfileReader.read(url) }.value
                    bytes = data
                    fileName = url.lastPathComponent
                    fileError = nil
                    password = ""
                } catch {
                    bytes = Data()
                    fileName = ""
                    fileError = error.localizedDescription
                }
            }
        }
        .onChange(of: ready, initial: true) { _, ok in submit.update(ok, commit) }
        // Keep the action's captured file/password current while readiness stays true.
        .onChange(of: password) { _, _ in fileError = nil; resetInspection() }
        .onChange(of: name) { _, _ in submit.update(ready, commit) }
        .onChange(of: bytes) { _, _ in resetInspection() }
        .onChange(of: expected) { _, _ in submit.update(ready, commit) }

        if !candidates.isEmpty {
            Section {
                Link("Prüfwerte auf der Commerzbank-Website öffnen", destination: URL(string: "https://www.commerzbank.de/service/kommunikationsadressen-ports-und-oeffentlicher-bankschluessel-fuer-hbci/")!)
                ForEach(candidates, id: \.keyType) { key in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(key.keyType == "S" ? "Signaturschlüssel" : "Verschlüsselungsschlüssel")
                            .appFont(.headline)
                        Text("\(key.bits) Bit · Schlüssel \(key.number), Version \(key.version)")
                            .appFont(.caption).foregroundStyle(.secondary)
                        Text(key.fingerprint).appFont(.caption, design: .monospaced)
                            .textSelection(.enabled)
                        TextField("SHA-256-Prüfwert laut Commerzbank", text: Binding(
                            get: { expected[key.keyType] ?? "" },
                            set: { expected[key.keyType] = $0 }
                        ))
                        .autocorrectionDisabled()
                        if normalized(expected[key.keyType] ?? "") == key.fingerprint {
                            Label("Prüfwerte stimmen überein", systemImage: "checkmark.shield")
                                .foregroundStyle(.green).appFont(.caption)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Bankschlüssel unabhängig bestätigen").appSectionHeader()
            } footer: {
                Text("Die empfangenen Schlüssel sind noch nicht vertrauenswürdig. Tragen Sie für beide Schlüssel den vollständigen SHA-256-Prüfwert aus der offiziellen Commerzbank-Quelle ein. Ein abweichender Prüfwert verhindert die Übernahme.")
                    .appFont(.caption)
            }
            .disabled(busy)
        }
    }

    private func resetInspection() {
        info = nil
        candidates = []
        expected = [:]
        submit.update(false, commit)
    }

    private func inspectFile() {
        guard !busy else { return }
        busy = true
        fileError = nil
        Task {
            do { info = try await model.inspectRah10File(bytes: bytes, password: password) }
            catch { info = nil; fileError = error.localizedDescription }
            busy = false
            submit.update(ready, commit)
        }
    }

    private func fetchKeys() {
        guard !busy, let info else { return }
        busy = true
        fileError = nil
        candidates = []
        expected = [:]
        Task {
            do { candidates = try await model.fetchRah10BankKeys(blz: info.blz) }
            catch { fileError = error.localizedDescription }
            busy = false
            submit.update(ready, commit)
        }
    }

    private func commit() {
        guard ready else { return }
        busy = true
        model.addRah10Connection(bytes: bytes, password: password, name: name,
            bankKeys: candidates, expected: candidates.map { expected[$0.keyType] ?? "" }) { success in
            busy = false
            if success {
                password = ""
                bytes = Data()
                onAdded()
            }
        }
    }
}
