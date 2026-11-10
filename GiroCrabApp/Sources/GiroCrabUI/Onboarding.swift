import SwiftUI
import GiroCrabCore

/// Shown above the stream while demo data is visible.
struct DemoBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "theatermasks.fill")
                .font(.title3)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Demo-Daten").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                Text(model.hasOwnVault
                     ? "Ihr eigener Tresor ist noch leer. Hier sehen Sie erfundene Buchungen aller 7 Banken."
                     : "Erfundene Buchungen aller 7 Banken – keine echte Bank verbunden.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(model.hasOwnVault ? "Eigener Tresor" : "Tresor öffnen") { model.showOwnVault() }
                .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.selection))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent.opacity(0.18), lineWidth: 1))
    }
}

/// Own vault without accounts: three steps + way back to the demo.
struct EmptyVaultCard: View {
    @Environment(AppModel.self) private var model
    @State private var addKind: ConnectorKind = .volksbankKasselGoettingen
    @State private var login = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Willkommen bei GiroCrab").font(.title3.weight(.semibold))
            Text("Ihr Tresor ist eingerichtet, enthält aber noch keine Konten. So geht es weiter:")
                .font(.callout).foregroundStyle(Theme.secondary)
            step(1, "Bank wählen und Anmeldenamen eingeben")
            step(2, "Fehlende Angaben ergänzen (z. B. FinTS-Produkt-ID, API-Schlüssel) – das Formular öffnet sich automatisch")
            step(3, "PIN eingeben und in der Banking-App freigeben")
            HStack(spacing: 8) {
                Picker("Bank", selection: $addKind) {
                    ForEach(bankCatalog()) { d in Text(d.name).tag(d.kind) }
                }
                .labelsHidden()
                .frame(width: 230)
                TextField(bankCatalog().first { $0.kind == addKind }?.loginLabel ?? String(localized: "Anmeldename"), text: $login)
                    .textFieldStyle(.roundedBorder)
                Button("Hinzufügen") {
                    model.addConnection(addKind, login: login)
                    login = ""
                }
                .buttonStyle(.borderedProminent)
            }
            Button { model.showMoneyMoneyImport = true } label: {
                Label("Von MoneyMoney wechseln", systemImage: "square.and.arrow.down.on.square")
            }
            Divider()
            HStack {
                Text("Erst einmal ansehen?").font(.caption).foregroundStyle(Theme.secondary)
                Button("Demo-Daten anzeigen") { model.showDemo() }
                    .buttonStyle(.borderless)
            }
        }
        .card()
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "\(n)")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.selection))
            Text(text).font(.callout).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Fill in what a bank still needs (FinTS product ID, API keys …), then sync.
struct BankSetupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: SetupRequest
    @State private var values: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                SymbolTile(symbol: request.connection.sfSymbol, tint: request.connection.connector.tint, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(request.connection.displayName) einrichten").font(.headline)
                    Text("Diese Angaben fehlen noch, bevor Buchungen abgerufen werden können.")
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
            }
            ForEach(request.keys, id: \.self) { key in
                let entry = model.settingEntry(key)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry?.label ?? settingLabels[key] ?? key).font(.callout.weight(.medium))
                    if key.contains("private_key") {
                        TextEditor(text: binding(key))
                            .font(.caption.monospaced())
                            .frame(height: 80)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                    } else if entry?.isSecret ?? key.contains("secret") {
                        SecureField("", text: binding(key))
                            .textFieldStyle(.roundedBorder)
                    } else {
                        TextField("", text: binding(key), prompt: Text(entry?.value.isEmpty == false ? entry!.value : ""))
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                    }
                    if let help = entry?.help { Text(help).font(.caption).foregroundStyle(Theme.secondary) }
                    if key == "fints.product_id" {
                        Link("Kostenlose FinTS-Produktregistrierung (Deutsche Kreditwirtschaft) öffnen",
                             destination: URL(string: "https://www.fints.org/de/hersteller/produktregistrierung")!)
                            .font(.caption)
                        Text("Die Registrierung dauert meist einige Tage. Bis dahin können Sie GiroCrab mit den Demo-Daten ausprobieren.")
                            .font(.caption2).foregroundStyle(Theme.tertiary)
                    }
                }
            }
            HStack {
                Button("Abbrechen", role: .cancel) { model.setupRequest = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
                if !model.demoActive {
                    Button("Demo-Daten ansehen") { model.setupRequest = nil; dismiss(); model.showDemo() }
                }
                Spacer()
                Button("Speichern & abrufen") { model.completeSetup(request, values: values) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(request.keys.allSatisfy { (values[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .padding(24)
        .macFrame(width: 520)
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }
}
