#if os(macOS)
import SwiftUI

/// Einstellungen › Allgemein › „Automatischer Abruf“: how often the balances
/// are fetched while GiroCrab runs (default off, kept in `UserDefaults`, so it
/// is active again after a relaunch). Logic: `AutoSync`.
struct AutoSyncSettingsSection: View {
    @Environment(AppModel.self) private var model
    /// -1 = never set; the picker then shows what the former hidden setting makes the loop use.
    @AppStorage(AutoSync.hoursKey) private var stored = -1

    private var selection: Binding<Int> {
        Binding(
            get: { stored >= 0 ? stored : model.autoSyncHours },
            set: { stored = $0 }
        )
    }

    var body: some View {
        let current = selection.wrappedValue
        Section {
            Picker("Automatischer Abruf", selection: selection) {
                ForEach(AutoSync.hourOptions, id: \.self) { Text(AutoSync.label($0)).tag($0) }
                // a value set elsewhere stays selectable
                if !AutoSync.hourOptions.contains(current) { Text(AutoSync.label(current)).tag(current) }
            }
            Text("Ruft die Kontostände im gewählten Abstand ab, solange GiroCrab läuft und der Tresor entsperrt ist. Bei gesperrtem Tresor wird der Abruf übersprungen und nach dem Entsperren nachgeholt. Es werden nur Zugänge mit gespeicherter PIN oder gültiger Freigabe abgerufen, nie mit einem Anmeldedialog.")
                .appFont(.caption).foregroundStyle(.secondary)
        } header: { Text("Abruf").appSectionHeader() }
    }
}
#endif
