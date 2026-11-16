import SwiftUI
import UniformTypeIdentifiers
import GiroCrabCore

struct MandateEditorSheet: View {
    @Environment(AppModel.self) private var model
    @State private var draft: MandateDraft

    init(initial: MandateDraft) { _draft = State(initialValue: initial) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    TextField("IBAN", text: $draft.iban)
                    TextField("BIC (optional)", text: $draft.bic)
                } header: { Text("Zahlungspflichtiger").appSectionHeader() }
                Section {
                    TextField("Mandatsreferenz", text: $draft.reference)
                    DatePicker("Unterschrieben am", selection: $draft.signed, in: ...Date(), displayedComponents: .date)
                    Picker("Art", selection: $draft.scheme) {
                        ForEach([MandateScheme.core, .cor1, .b2b], id: \.self) { Text($0.title).tag($0) }
                    }
                    Toggle("Einmaliges Mandat", isOn: $draft.oneOff)
                        .help("EM = Einmalmandat (eine einzelne Lastschrift), AM = Dauermandat (wiederkehrende Lastschriften).")
                    Toggle("Aktiv", isOn: $draft.active)
                } header: { Text("Mandat").appSectionHeader() }
                Section {
                    TextField("Betrag (optional)", text: $draft.amountText)
                    TextField("Verwendungszweck (optional)", text: $draft.purpose)
                    TextField("Notiz (optional)", text: $draft.note)
                } header: { Text("Vorgaben für den Einzug").appSectionHeader() }
            }
            .formStyle(.grouped)
            if let error = model.mandateError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .appFont(.callout).foregroundStyle(Theme.negative)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { model.mandateDraft = nil }.keyboardShortcut(.cancelAction)
                Button("Sichern") { model.mandateDraft = draft; model.saveMandateDraft() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(14)
        }
        #if os(macOS)
        .frame(width: 460, height: 640)
        #endif
    }
}
