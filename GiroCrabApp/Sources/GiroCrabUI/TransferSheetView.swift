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
    @Environment(\.textScale) private var textScale
    @State private var step: Step = .form
    @State private var exportingGiroCode: PNGFileDocument?
    @State private var suggestions: [KnownRecipient] = []
    @FocusState private var nameFocused: Bool
    @State private var dropTargeted = false
    @State private var importNote: String?
    /// "Umbuchung": the recipient is one of the user's own accounts.
    @State private var ownTransfer = false
    @State private var ownTargetID: Int64?
    /// Measured form and sheet heights: the sheet takes what the form needs (#879).
    @State private var formFit = FormFit()
    /// Opt-in clipboard check (#663): what the banner offers.
    @State private var clipboardOffer: ClipboardPaymentCheck.Offer?
    @AppStorage(ClipboardPaymentCheck.enabledKey) private var clipboardCheck = ClipboardPaymentCheck.enabledDefault

    private let maxPurpose = 140

    /// The form, then either the review before sending or the GiroCode.
    enum Step { case form, review, giroCode }

    /// Own accounts that can receive a transfer: any kind, but with an IBAN, not archived, not the sender.
    private var ownTargets: [Account] {
        // Tagesgeld books only to own checking accounts (#582).
        if let a = account, a.kind == .savings { return model.internalTransferTargets(from: a) }
        return model.allAccounts.filter {
            !$0.iban.isEmpty && !$0.isArchived && $0.id != model.transferDraft.accountID
        }
    }

    /// Fills name and IBAN from the chosen own account (owner, else account name).
    private func applyOwnTarget(_ id: Int64?) {
        guard let t = ownTargets.first(where: { $0.id == id }) else { return }
        model.transferDraft.name = t.owner.isEmpty ? t.name : t.owner
        model.transferDraft.iban = t.iban
        model.transferDraft.bic = ""
        suggestions = []
    }

    private func setOwnTransfer(_ on: Bool) {
        ownTransfer = on
        if on {
            if !ownTargets.contains(where: { $0.id == ownTargetID }) { ownTargetID = ownTargets.first?.id }
            applyOwnTarget(ownTargetID)
        } else {
            model.transferDraft.name = ""
            model.transferDraft.iban = ""
            model.transferDraft.bic = ""
        }
    }

    /// Savings account as sender: the bank allows only an internal transfer (#582).
    private var internalOnly: Bool { account?.kind == .savings }

    private var account: Account? {
        model.transferFormAccounts.first { $0.id == model.transferDraft.accountID }
    }
    /// The account can send from GiroCrab (FinTS / bunq); otherwise the form
    /// ends with a GiroCode for the bank's app.
    private var canSend: Bool {
        model.canSendTransfer(from: account?.id)
    }
    private var giroCodePayload: String? {
        guard let cents else { return nil }
        let d = model.transferDraft
        return GiroCode.payload(name: d.name, iban: d.iban, bic: bicText, amountCents: cents, purpose: d.purpose)
    }
    private var ibanValid: Bool { validateIban(iban: model.transferDraft.iban) }
    private var bicText: String { model.transferDraft.bic.trimmingCharacters(in: .whitespaces) }
    private var bicValid: Bool { bicText.isEmpty || Self.looksLikeBIC(bicText) }
    private var cents: Int64? {
        guard let c = try? parseAmountToCents(text: model.transferDraft.amountText), c > 0 else { return nil }
        return c
    }
    private var isBunq: Bool { account?.connector == .bunq }
    private var sendsInstant: Bool {
        model.transferDraft.instant && account?.connector?.offersInstantChoice == true
    }
    private var isMagicDemoAccount: Bool {
        guard let id = account?.connectionId,
              let c = model.connections.first(where: { $0.id == id }) else { return false }
        return AppModel.isMagicDemoLogin(c.loginName)
    }
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

    /// The height the form needs (#879), at most what the screen offers;
    /// `nil` (fixed 700 pt) until measured or before macOS 15.
    private var fittedHeight: CGFloat? {
        #if os(macOS)
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        return formFit.height(min: 420, max: screen - 120)
        #else
        return nil
        #endif
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            if step == .form && model.canBatchTransfer {
                TransferKindPicker(batch: false).padding(.bottom, 10)
            }
            if step == .form, let offer = clipboardOffer {
                ClipboardPaymentBanner(offer: offer, apply: { acceptClipboard($0) }, ignore: { clipboardOffer = nil })
                    .padding(.horizontal, 20).padding(.bottom, 10)
            }
            Divider()
            switch step {
            case .form: form(draft: $model.transferDraft)
            case .review: sendConfirmation
            case .giroCode: giroCodeView
            }
            if model.transferError != nil || model.transferInstantDeclined != nil {
                VStack(alignment: .leading, spacing: 8) {
                    if let e = model.transferError {
                        Label(e, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.negative).appFont(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let reason = model.transferInstantDeclined {
                        instantDeclined(reason)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.bottom, 12)
            }
            Divider()
            buttons.padding(14)
        }
        .macFrame(width: 560, height: fittedHeight == nil ? 700 : nil)
        .frame(height: fittedHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { formFit.total = $0 }
        // The GiroCode view does not scroll: back to the fixed height.
        .onChange(of: step) { formFit = FormFit(total: formFit.total) }
        .task { // screenshots
            switch model.options.demoSheetName {
            case "transfer-confirm": step = .review
            case "transfer-girocode": step = .giroCode
            default: break
            }
        }
        .task { // the demo offers fictional data and leaves the real clipboard untouched
            if model.options.demoSheetName == "transfer-clipboard" {
                clipboardOffer = ClipboardPaymentCheck.offer(for: .demo)
                return
            }
            let offer = await ClipboardPaymentCheck.filtered(checkClipboard())
            // the pattern detection is async: offer only on a still open, still empty form
            guard step == .form, ClipboardPaymentCheck.isEmpty(model.transferDraft, ownTransfer: ownTransfer) else { return }
            clipboardOffer = offer
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Theme.accent.opacity(0.06)).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard step == .form, let p = providers.first else { return false }
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
        .onAppear { if internalOnly && !ownTransfer { setOwnTransfer(true) } }
        .onChange(of: model.transferDraft.accountID) { _, _ in
            if internalOnly && !ownTransfer { setOwnTransfer(true); return }
            if !internalOnly && ownTransfer && ownTargets.isEmpty { setOwnTransfer(false); return }
            guard ownTransfer else { return }
            if !ownTargets.contains(where: { $0.id == ownTargetID }) { ownTargetID = ownTargets.first?.id }
            applyOwnTarget(ownTargetID)
        }
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

    private var title: LocalizedStringKey {
        switch step {
        case .form: "Neue Überweisung"
        case .review: "Überweisung prüfen"
        case .giroCode: "GiroCode scannen"
        }
    }

    /// Title left, the two helpers (templates, paste) as small actions right.
    private var header: some View {
        HStack(spacing: 12) {
            Text(title).appFont(.title2, weight: .semibold)
            Spacer()
            if step == .form {
                TransferTemplatesMenu()
                #if os(macOS)
                Button { pasteFromClipboard() } label: { Label("Einfügen", systemImage: "doc.on.clipboard") }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .help("Erkennt IBAN, Betrag, Empfänger und Zweck (⇧⌘V; ⌘V außerhalb von Textfeldern). Rechnung (PDF, ZUGFeRD, GiroCode) hierher ziehen.")
                #else
                PaymentPasteButton { report(PaymentParser.parseText($0)) }
                    .labelStyle(.iconOnly)
                #endif
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: form

    private func form(draft: Binding<TransferDraft>) -> some View {
        Form {
            Section {
                LabeledContent("Von Konto") {
                    SourceAccountPicker(selection: draft.accountID, accounts: model.transferFormAccounts)
                }
            } footer: {
                if account != nil && !canSend { noDirectTransferNote }
            }

            if internalOnly {
                Section {
                    Label("Vom Tagesgeldkonto sind nur Umbuchungen auf eigene Girokonten möglich.", systemImage: "arrow.left.arrow.right")
                        .appFont(.callout)
                }
            } else if !ownTargets.isEmpty || ownTransfer {
                Section {
                    Picker("Art der Zahlung", selection: Binding(get: { ownTransfer }, set: { setOwnTransfer($0) })) {
                        Text("Überweisung").tag(false)
                        Text("Umbuchung").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            if ownTransfer {
                Section {
                    Picker("Zielkonto", selection: Binding(get: { ownTargetID }, set: { ownTargetID = $0; applyOwnTarget($0) })) {
                        ForEach(ownTargets) { a in
                            Text("\(a.name) · \(formatIBAN(a.iban))").tag(Optional(a.id)).sensitive()
                        }
                    }
                    LabeledContent("Name") {
                        Text(draft.wrappedValue.name).appFont(.body).sensitive()
                    }
                    LabeledContent("IBAN") {
                        Text(formatIBAN(draft.wrappedValue.iban)).appFont(.body, design: .monospaced).sensitive()
                    }
                } header: {
                    Text("Eigenes Zielkonto").appSectionHeader()
                } footer: {
                    Text("Name und IBAN werden aus dem gewählten Konto übernommen.")
                }
            } else {
            Section {
                TextField("Name", text: draft.name, prompt: Text("Name des Empfängers"))
                    .multilineTextAlignment(.trailing)
                    .focused($nameFocused)
                    .sensitive()
                if !suggestions.isEmpty { suggestionRow }
                LabeledContent("IBAN") {
                    HStack(spacing: 8) {
                        TextField("IBAN", text: draft.iban, prompt: Text("DE00 0000 0000 0000 0000 00"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .appFont(.body, design: .monospaced)
                            .autocorrectionDisabled()
                            .sensitive()
                        if !draft.wrappedValue.iban.isEmpty {
                            Image(systemName: ibanValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(ibanValid ? Theme.inflow : Theme.negative)
                                .help(ibanValid ? "Prüfsumme korrekt" : "IBAN ungültig (Prüfsumme/Länge)")
                                .accessibilityLabel(ibanValid ? "Prüfsumme korrekt" : "IBAN ungültig (Prüfsumme/Länge)")
                        }
                    }
                }
                LabeledContent("BIC (optional)") {
                    HStack(spacing: 8) {
                        TextField("BIC", text: draft.bic, prompt: Text("z. B. GENODEF1KS2"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .appFont(.body, design: .monospaced)
                            .autocorrectionDisabled()
                            .sensitive()
                        if !bicText.isEmpty {
                            Image(systemName: bicValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(bicValid ? Theme.inflow : Theme.negative)
                                .help(bicValid ? "BIC gültig" : "BIC ungültig")
                                .accessibilityLabel(bicValid ? "BIC gültig" : "BIC ungültig")
                        }
                    }
                }
            } header: {
                Text("Empfänger").appSectionHeader()
            } footer: {
                Text(importNote ?? String(localized: "Oder Rechnung hierher ziehen"))
            }
            }

            Section {
                LabeledContent("Betrag") {
                    HStack(spacing: 6) {
                        TextField("Betrag", text: draft.amountText, prompt: Text(Money.plain(0)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .appFont(.body, monospacedDigit: true)
                            .sensitive(.amounts)
                        Text("€").foregroundStyle(Theme.secondary)
                    }
                }
                TextField("Verwendungszweck", text: draft.purpose, prompt: Text("Verwendungszweck"), axis: .vertical)
                    .lineLimit(1...3)
                    .sensitive()
            } header: {
                Text("Zahlung").appSectionHeader()
            } footer: {
                HStack {
                    if !draft.wrappedValue.amountText.isEmpty && cents == nil {
                        Text("Betrag > 0 eingeben").foregroundStyle(Theme.negative)
                    }
                    Spacer()
                    Text("\(draft.wrappedValue.purpose.count)/\(maxPurpose)")
                        .monospacedDigit()
                        .foregroundStyle(draft.wrappedValue.purpose.count >= maxPurpose ? Theme.negative : Theme.tertiary)
                }
            }

            if canSend && account?.connector?.offersInstantChoice == true {
                Section {
                    // Mutually exclusive choices: one radio group (HIG), not
                    // two checkboxes where one disables the other.
                    Picker("Art", selection: executionMode(draft)) {
                        Text("Normale Überweisung").tag(ExecutionMode.regular)
                        Text("Terminüberweisung").tag(ExecutionMode.scheduled)
                        Text("Echtzeitüberweisung (SEPA Instant)").tag(ExecutionMode.instant)
                    }
                    #if os(macOS)
                    .pickerStyle(.radioGroup)
                    #else
                    .pickerStyle(.menu)
                    #endif
                    .labelsHidden()
                    if draft.wrappedValue.executionMode == .scheduled {
                        DatePicker("Ausführungsdatum", selection: draft.executionDate,
                                   in: (Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())...,
                                   displayedComponents: .date)
                    }
                } header: {
                    Text("Ausführung").appSectionHeader()
                } footer: {
                    if draft.wrappedValue.executionMode == .instant { instantNote }
                }
            }

            if canSend && (model.isDemo || isMagicDemoAccount) {
                Section {
                    DemoHintBanner(style: .pinAndTan, buttonTitle: "PIN 12345 einfügen") { draft.pin.wrappedValue = "12345" }
                }
            }
            if canSend && !pinStored {
                Section {
                    SecureField(isBunq ? "bunq-API-Schlüssel" : "Banking-PIN", text: draft.pin,
                                prompt: Text(isBunq ? "wird nicht gespeichert" : "wird nicht gespeichert"))
                        .multilineTextAlignment(.trailing)
                } footer: {
                    Text(isBunq ? "Der API-Schlüssel wird nicht gespeichert." : "Die PIN wird nicht gespeichert.")
                }
            }
        }
        .formStyle(.grouped)
        .reportsFormFit($formFit)
    }

    private var suggestionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(suggestions, id: \.iban) { r in
                    Button {
                        model.transferDraft.name = r.name
                        model.transferDraft.iban = r.iban
                        suggestions = []
                    } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(r.name).appFont(.callout).lineLimit(1)
                            Text(formatIBAN(r.iban)).appFont(.caption2, design: .monospaced).foregroundStyle(Theme.secondary)
                        }
                        .sensitive() // known recipients: name and IBAN
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.selection))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Why this account ends in a GiroCode instead of a direct transfer.
    @ViewBuilder private var noDirectTransferNote: some View {
        if model.bankingGate(forAccount: account?.id) != nil {
            // Security lock: no direct transfer, the GiroCode needs no bank contact.
            Label("Die Sicherheitssperre verhindert direkte Überweisungen von diesem Konto. Am Ende erhalten Sie einen GiroCode zum Scannen in der App Ihrer Bank.", systemImage: "exclamationmark.shield")
        } else if account?.connector == .comdirect {
            // The comdirect REST API has no payment endpoint; FinTS has.
            Label("Die comdirect-Schnittstelle (REST) kann keine Überweisungen ausführen. Verbinden Sie das Konto zusätzlich per FinTS, um direkt zu überweisen. Sonst erhalten Sie am Ende einen GiroCode zum Scannen in der comdirect-App.", systemImage: "qrcode")
        } else {
            Label("Von diesem Konto kann GiroCrab nicht direkt überweisen. Am Ende erhalten Sie einen GiroCode zum Scannen in der App Ihrer Bank.", systemImage: "qrcode")
        }
    }

    @ViewBuilder private var instantNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Kommt in Sekunden an und ist nicht rückholbar. Bietet die Bank sie nicht an, wird nichts gesendet; Sie können sie dann als normale Überweisung senden.")
            if let c = cents, c >= 10_000_000 {
                Label("Viele Banken begrenzen Echtzeitüberweisungen (oft auf 100.000 € oder ein eigenes Limit). Die Bank kann den Auftrag dann ablehnen.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warning)
            }
        }
    }

    private func executionMode(_ draft: Binding<TransferDraft>) -> Binding<ExecutionMode> {
        Binding(get: { draft.wrappedValue.executionMode }, set: { draft.wrappedValue.executionMode = $0 })
    }

    // MARK: confirmation

    /// The transfer as EPC QR code for the bank's app: the only way out for
    /// read-only accounts (e.g. C24), on request for sendable ones.
    private var giroCodeView: some View {
        let d = model.transferDraft
        let payload = giroCodePayload
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                Group {
                    if let payload, let cg = GiroCode.image(for: payload) {
                        Image(decorative: cg, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .accessibilityLabel(Text("GiroCode"))
                    } else {
                        Image(systemName: "qrcode").resizable().foregroundStyle(Theme.tertiary)
                    }
                }
                .frame(width: 200, height: 200)
                .sensitive() // the code carries name, IBAN, amount and purpose
                VStack(alignment: .leading, spacing: 8) {
                    amountHeadline
                    summaryRow("An", d.name)
                    summaryRow("IBAN", d.iban)
                    if !bicText.isEmpty { summaryRow("BIC", bicText.uppercased()) }
                    summaryRow("Zweck", d.purpose.isEmpty ? "–" : d.purpose)
                    summaryRow("Von", account.map { "\($0.name) · \(formatIBAN($0.iban))" } ?? "–")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
            if let payload { giroCodeActions(payload) }
            Label("In der App Ihrer Bank „Fotoüberweisung“ bzw. „QR-Code scannen“ wählen, den Code scannen und dort mit TAN freigeben. GiroCrab sendet nichts.", systemImage: "camera.viewfinder")
                .appFont(.callout).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if canSend {
                Label("Ausführungsdatum und Echtzeitüberweisung wählen Sie in der App Ihrer Bank; ein GiroCode enthält sie nicht.", systemImage: "info.circle")
                    .appFont(.callout).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        #if os(macOS)
        .fileExporter(isPresented: Binding(get: { exportingGiroCode != nil }, set: { if !$0 { exportingGiroCode = nil } }),
                      document: exportingGiroCode, contentType: .png, defaultFilename: "GiroCode.png") { _ in }
        #endif
    }

    /// Copy / save (macOS) or share (iOS) the code as a picture.
    private func giroCodeActions(_ payload: String) -> some View {
        HStack(spacing: 8) {
            #if os(macOS)
            Button("Bild kopieren", systemImage: "doc.on.doc") {
                if let png = GiroCode.png(for: payload) { BugReport.copyToPasteboard(png) }
            }
            Button("Sichern …", systemImage: "square.and.arrow.down") {
                exportingGiroCode = GiroCode.png(for: payload).map(PNGFileDocument.init(data:))
            }
            #else
            ShareLink(item: GiroCodeImage(payload: payload), preview: SharePreview("GiroCode")) {
                Label("Bild teilen", systemImage: "square.and.arrow.up")
            }
            #endif
        }
        .help("Das Bild enthält IBAN, Empfänger und Betrag.")
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// The amount at the top of the review and the GiroCode step.
    private var amountHeadline: some View {
        Text(Money.format(cents ?? 0))
            .appFont(.largeTitle, weight: .semibold, monospacedDigit: true)
            .sensitive(.amounts)
    }

    /// Read-only review in the same grouped style as the form: the amount first,
    /// then recipient, payment and execution, each as label + value.
    private var sendConfirmation: some View {
        let d = model.transferDraft
        return Form {
            Section {
                amountHeadline
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            }
            Section {
                reviewRow("Name", d.name)
                reviewRow("IBAN", d.iban, monospaced: true)
                if !bicText.isEmpty { reviewRow("BIC", bicText.uppercased(), monospaced: true) }
            } header: {
                Text("Empfänger").appSectionHeader()
            }
            Section {
                reviewRow("Verwendungszweck", d.purpose.isEmpty ? "–" : d.purpose)
                reviewRow("Von Konto", account.map { "\($0.name) · \(formatIBAN($0.iban))" } ?? "–")
                reviewRow("Ausführung", sendsInstant
                    ? String(localized: "Sofort (Echtzeitüberweisung)")
                    : d.executionDateISO.map { String(format: String(localized: "Am %@ (Terminüberweisung)"), $0) }
                        ?? String(localized: "Heute (SEPA-Überweisung)"), hides: [])
            } header: {
                Text("Zahlung").appSectionHeader()
            } footer: {
                Label("Bitte Empfänger und IBAN genau prüfen. Eine freigegebene Überweisung lässt sich meist nicht mehr zurückholen.", systemImage: "exclamationmark.shield")
            }
        }
        .formStyle(.grouped)
        .reportsFormFit($formFit)
    }

    private func reviewRow(_ label: LocalizedStringKey, _ value: String, monospaced: Bool = false,
                           hides: ReportRedaction = .personal) -> some View {
        LabeledContent(label) {
            Text(value)
                .appFont(.body, design: monospaced ? .monospaced : .default)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .sensitive(hides)
        }
    }

    /// Rows of the GiroCode review: all of them are personal.
    private func summaryRow(_ k: LocalizedStringKey, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(Theme.secondary).frame(width: 90 * textScale, alignment: .leading)
            Text(v).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).sensitive()
            Spacer(minLength: 0)
        }
    }

    /// Instant was not possible and nothing was sent: offer a regular
    /// transfer, which needs its own approval.
    private func instantDeclined(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Echtzeitüberweisung nicht ausgeführt", systemImage: "bolt.slash.fill")
                .appFont(.callout, weight: .bold)
            Text(String(format: String(localized: "Es wurde kein Geld gesendet. Grund der Bank: %@"), reason))
                .appFont(.callout).fixedSize(horizontal: false, vertical: true)
            Button("Als normale Überweisung senden") { model.sendAsRegularTransfer() }
                .disabled(model.transferBusy)
            Text("Kommt in der Regel am nächsten Bankarbeitstag an. Sie geben sie erneut frei.")
                .appFont(.caption).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: buttons

    private var buttons: some View {
        HStack {
            switch step {
            case .giroCode:
                Button("Zurück") { step = .form }
                Spacer()
                Button("Fertig") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            case .review:
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Zurück") { step = .form }
                Button(isBunq ? "In der bunq-App freigeben" : "Jetzt mit TAN freigeben") { model.startTransfer() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.transferBusy)
            case .form:
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if canSend {
                    // nothing is sent, so no PIN needed
                    Button("Als GiroCode anzeigen") { leaveForm(to: .giroCode) }
                        .disabled(!canReview || giroCodePayload == nil)
                }
                let next: Step = canSend ? .review : .giroCode
                Button(next == .review ? "Weiter" : "GiroCode erstellen") { leaveForm(to: next) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canReview || (canSend && !pinStored && model.transferDraft.pin.isEmpty)
                              || (!canSend && giroCodePayload == nil))
            }
        }
    }

    private func leaveForm(to next: Step) {
        model.transferError = nil
        step = next
    }

    // MARK: clipboard / invoice drop

    #if os(macOS)
    private func pasteFromClipboard() {
        report(PaymentParser.parseClipboard())
    }
    #endif

    private func importInvoice(_ url: URL) async {
        importNote = String(localized: "Lese Rechnung …")
        report(await PaymentParser.parseFile(url) ?? ParsedPayment())
    }

    private func report(_ p: ParsedPayment, onlyEmpty: Bool = false) {
        guard !p.isEmpty else { importNote = String(localized: "Nichts Erkennbares gefunden"); return }
        p.apply(to: &model.transferDraft, onlyEmpty: onlyEmpty)
        importNote = String(localized: "Felder ausgefüllt – bitte prüfen")
    }

    /// Opt-in (#663): offers the clipboard as a payment when the empty form opens.
    private func checkClipboard() -> ClipboardPaymentCheck.Offer? {
        guard clipboardCheck else { return nil }
        return ClipboardPaymentCheck.check(
            draftEmpty: ClipboardPaymentCheck.isEmpty(model.transferDraft, ownTransfer: ownTransfer),
            lastHandled: &model.clipboardChangeCountHandled)
    }

    private func acceptClipboard(_ p: ParsedPayment) {
        clipboardOffer = nil
        report(p, onlyEmpty: true)
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

/// "Von Konto" of the transfer, standing order and batch forms: the picker
/// draws the selected account's name and IBAN itself (an iOS menu picker),
/// so it is covered as a whole; the label beside it stays readable.
struct SourceAccountPicker: View {
    let selection: Binding<Int64?>
    let accounts: [Account]

    var body: some View {
        Picker("Von Konto", selection: selection) {
            ForEach(accounts) { a in
                Text("\(a.name) · \(formatIBAN(a.iban))").tag(Optional(a.id))
            }
        }
        .labelsHidden()
        .sensitive()
    }
}
