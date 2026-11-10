import SwiftUI
import GiroCrabCore
#if os(macOS)
import AppKit
#endif

/// "Neue Überweisung": SEPA credit transfer via FinTS (HKCCS). After the
/// confirmation card the model starts the session; the bank's TAN request is
/// shown by the existing `TwoFactorSheet`.
struct TransferSheetView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false
    @State private var suggestions: [KnownRecipient] = []
    @FocusState private var nameFocused: Bool
    @State private var dropTargeted = false
    @State private var importNote: String?

    private let maxPurpose = 140

    private var account: Account? {
        model.transferAccounts.first { $0.id == model.transferDraft.accountID }
    }
    private var ibanValid: Bool { validateIban(iban: model.transferDraft.iban) }
    private var bicText: String { model.transferDraft.bic.trimmingCharacters(in: .whitespaces) }
    private var bicValid: Bool { bicText.isEmpty || Self.looksLikeBIC(bicText) }
    private var cents: Int64? {
        guard let c = try? parseAmountToCents(text: model.transferDraft.amountText), c > 0 else { return nil }
        return c
    }
    private var isBunq: Bool { account?.connector == .bunq }
    private var pinStored: Bool {
        guard let id = account?.connectionId else { return false }
        return model.isDemo || (model.connectionStatus(id)?.hasPin ?? false)
    }
    private var canReview: Bool {
        account != nil
            && !model.transferDraft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && ibanValid && bicValid && cents != nil
            && model.transferDraft.purpose.count <= maxPurpose
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "paperplane.circle.fill").font(.title).foregroundStyle(Theme.accent)
                Text(confirming ? "Überweisung prüfen" : "Neue Überweisung").font(.title2.bold())
                Spacer()
            }
            if confirming { confirmation } else { form(draft: $model.transferDraft) }
            if let e = model.transferError {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .padding(24)
        .macFrame(width: 520)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Theme.accent.opacity(0.06)).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard !confirming, let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in await importInvoice(url) }
            }
            return true
        }
        // ⌘V outside a text field (inside one, normal paste keeps working).
#if os(macOS)
        .onPasteCommand(of: [.plainText]) { _ in pasteFromClipboard() }
#endif
        .onChange(of: model.transferDraft.iban) { _, new in
            let f = Self.groupedIBAN(new)
            if f != new { model.transferDraft.iban = f }
        }
        .onChange(of: model.transferDraft.purpose) { _, new in
            if new.count > maxPurpose { model.transferDraft.purpose = String(new.prefix(maxPurpose)) }
        }
        .onChange(of: model.transferDraft.name) { _, new in
            suggestions = nameFocused ? model.suggestRecipients(new) : []
        }
        .onChange(of: nameFocused) { _, f in
            suggestions = f ? model.suggestRecipients(model.transferDraft.name) : []
        }
    }

    // MARK: form

    private func form(draft: Binding<TransferDraft>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button { pasteFromClipboard() } label: { Label("Aus Zwischenablage einfügen", systemImage: "doc.on.clipboard") }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .help("Erkennt IBAN, Betrag, Empfänger und Zweck (⇧⌘V; ⌘V außerhalb von Textfeldern). Rechnung (PDF, ZUGFeRD, GiroCode) hierher ziehen.")
                Text(importNote ?? String(localized: "Oder Rechnung hierher ziehen"))
                    .font(.caption).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            HStack { Spacer(); TransferTemplatesMenu() }
            field("Von Konto") {
                Picker("", selection: draft.accountID) {
                    ForEach(model.transferAccounts) { a in
                        Text("\(a.name) · \(formatIBAN(a.iban))").tag(Optional(a.id))
                    }
                }
                .labelsHidden()
            }
            field("Empfänger") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Name des Empfängers", text: draft.name)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                    if !suggestions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(suggestions, id: \.iban) { r in
                                    Button {
                                        model.transferDraft.name = r.name
                                        model.transferDraft.iban = r.iban
                                        suggestions = []
                                    } label: {
                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(r.name).font(.callout).lineLimit(1)
                                            Text(formatIBAN(r.iban)).font(.caption2.monospaced()).foregroundStyle(Theme.secondary)
                                        }
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.selection))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            field("IBAN") {
                HStack(spacing: 8) {
                    TextField("DE00 0000 0000 0000 0000 00", text: draft.iban)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                    if !draft.wrappedValue.iban.isEmpty {
                        Image(systemName: ibanValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(ibanValid ? Color.green : Color.red)
                            .help(ibanValid ? "Prüfsumme korrekt" : "IBAN ungültig (Prüfsumme/Länge)")
                    }
                }
            }
            field("BIC (optional)") {
                HStack(spacing: 8) {
                    TextField("z. B. GENODEF1KS2", text: draft.bic)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                    if !bicText.isEmpty {
                        Image(systemName: bicValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(bicValid ? Color.green : Color.red)
                    }
                }
            }
            field("Betrag") {
                HStack(spacing: 6) {
                    TextField(Money.plain(0), text: draft.amountText)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospacedDigit())
                        .frame(maxWidth: 160)
                    Text("€").foregroundStyle(Theme.secondary)
                    if !draft.wrappedValue.amountText.isEmpty && cents == nil {
                        Text("Betrag > 0 eingeben").font(.caption).foregroundStyle(.red)
                    }
                }
            }
            field("Verwendungszweck") {
                VStack(alignment: .trailing, spacing: 2) {
                    TextField("Verwendungszweck", text: draft.purpose, axis: .vertical)
                        .lineLimit(2...3)
                        .textFieldStyle(.roundedBorder)
                    Text("\(draft.wrappedValue.purpose.count)/\(maxPurpose)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(draft.wrappedValue.purpose.count >= maxPurpose ? Color.red : Theme.tertiary)
                }
            }
            if !pinStored {
                field(isBunq ? "bunq-API-Schlüssel" : "Banking-PIN") {
                    SecureField(isBunq ? "API-Schlüssel (wird nicht gespeichert)" : "PIN (wird nicht gespeichert)", text: draft.pin)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private func field<C: View>(_ label: LocalizedStringKey, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(Theme.secondary).frame(width: 140, alignment: .trailing)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: confirmation

    private var confirmation: some View {
        let d = model.transferDraft
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text(Money.format(-(cents ?? 0)).replacingOccurrences(of: "-", with: ""))
                    .font(.system(size: 32, weight: .semibold).monospacedDigit())
                summaryRow("An", d.name)
                summaryRow("IBAN", d.iban)
                if !bicText.isEmpty { summaryRow("BIC", bicText.uppercased()) }
                summaryRow("Zweck", d.purpose.isEmpty ? "–" : d.purpose)
                Divider()
                summaryRow("Von", account.map { "\($0.name) · \(formatIBAN($0.iban))" } ?? "–")
                summaryRow("Ausführung", String(localized: "Heute (SEPA-Überweisung)"))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
            Label("Bitte Empfänger und IBAN genau prüfen. Eine freigegebene Überweisung lässt sich meist nicht mehr zurückholen.", systemImage: "exclamationmark.shield")
                .font(.callout).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func summaryRow(_ k: LocalizedStringKey, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(Theme.secondary).frame(width: 90, alignment: .leading)
            Text(v).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: buttons

    private var buttons: some View {
        HStack {
            if confirming {
                Button("Zurück") { confirming = false }
                Spacer()
                Button(isBunq ? "In der bunq-App freigeben" : "Jetzt mit TAN freigeben") { model.startTransfer() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.transferBusy)
            } else {
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Weiter") { model.transferError = nil; confirming = true }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canReview || (!pinStored && model.transferDraft.pin.isEmpty))
            }
        }
    }

    // MARK: Sm@rtPaste / invoice drop

    private func pasteFromClipboard() {
        #if os(macOS)
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        #else
        let text = UIPasteboard.general.string ?? ""
        #endif
        report(PaymentParser.parseText(text))
    }

    private func importInvoice(_ url: URL) async {
        importNote = String(localized: "Lese Rechnung …")
        report(await PaymentParser.parseFile(url) ?? ParsedPayment())
    }

    private func report(_ p: ParsedPayment) {
        guard !p.isEmpty else { importNote = String(localized: "Nichts Erkennbares gefunden"); return }
        p.apply(to: &model.transferDraft)
        importNote = String(localized: "Felder ausgefüllt – bitte prüfen")
    }

    // MARK: helpers

    /// Upper-case, only A–Z/0–9, groups of four.
    static func groupedIBAN(_ raw: String) -> String {
        let clean = raw.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return stride(from: 0, to: clean.count, by: 4).map { i -> String in
            let s = clean.index(clean.startIndex, offsetBy: i)
            let e = clean.index(s, offsetBy: min(4, clean.count - i))
            return String(clean[s..<e])
        }.joined(separator: " ")
    }

    static func looksLikeBIC(_ s: String) -> Bool {
        let u = Array(s.uppercased())
        guard u.count == 8 || u.count == 11 else { return false }
        return u[..<6].allSatisfy { $0.isASCII && $0.isLetter } && u[6...].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
