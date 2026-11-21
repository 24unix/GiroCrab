import SwiftUI
import GiroCrabCore

/// Repayment progress of a loan plus the editable "Ursprünglicher Kreditbetrag"
/// (HKSAL only reports the remaining balance, so live loans need it entered once).
struct LoanProgressCard: View {
    @Environment(AppModel.self) private var model
    let account: Account
    var compact = false
    @State private var text = ""
    @State private var editing = false
    @Environment(\.textScale) private var textScale

    private var manual: ManualLoan? { model.manualLoan(account.id) }
    private var initial: Int64? { account.initialBalanceCents.map { abs($0) }.flatMap { $0 > 0 ? $0 : nil } }
    private var repaid: Double? {
        guard let p = initial else { return nil }
        return max(0, min(1, 1 - Double(abs(account.balanceCents)) / Double(p)))
    }

    /// Amount field with cancel (✕) and save (✓) as pictograms: words squeezed
    /// next to the heading shrank to "…". The names stay as help and for VoiceOver.
    @ViewBuilder private var editor: some View {
        HStack(spacing: 6) {
            TextField("z. B. \(Money.plain(28_000_000))", text: $text)
                .textFieldStyle(.roundedBorder).onSubmit(commit)
                .frame(minWidth: 90 * textScale, maxWidth: compact ? 130 * textScale : .infinity)
                .sensitive(.amounts)
            Button { editing = false } label: { Label("Abbrechen", systemImage: "xmark").labelStyle(.iconOnly) }
                .controlSize(.small).keyboardShortcut(.cancelAction)
                .help("Abbrechen")
                .fixedSize()
            Button(action: commit) { Label("Speichern", systemImage: "checkmark").labelStyle(.iconOnly) }
                .controlSize(.small).keyboardShortcut(.defaultAction)
                .help("Speichern")
                .fixedSize()
        }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            model.setAccountInitialBalance(account.id, cents: nil)
        } else if let c = Money.parseCents(trimmed) {
            model.setAccountInitialBalance(account.id, cents: c)
        }
        editing = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // heading and share; in the card the amount gets the next row, so a
            // narrow detail column never breaks "Tilgung" in the middle of the word
            HStack {
                if !compact { Label("Tilgung", systemImage: "house").appFont(.headline).fixedSize() }
                if let repaid {
                    Text("\(repaid.formatted(.percent.precision(.fractionLength(0)))) getilgt")
                        .sensitive(.amounts)
                        .appFont(.callout, weight: .semibold).foregroundStyle(Theme.loan)
                        .fixedSize()
                } else {
                    Text("Ursprünglicher Kreditbetrag fehlt").appFont(.caption).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
                if compact { amountControls }
            }
            if !compact { amountControls }
            if let repaid {
                ProgressView(value: repaid).progressViewStyle(.linear).tint(Theme.loan)
                    .sensitive(.amounts)
                    .accessibilityLabel("Tilgung")
                    .accessibilityValue("\(repaid.formatted(.percent.precision(.fractionLength(0)))) getilgt")
            }
            if let manual, !compact {
                ManualLoanDetails(loan: manual)
            }
        }
        .modifier(CardIf(enabled: !compact))
    }

    /// The original amount: a button to edit it, the editor, or for manual loans
    /// (amount, Stand and rate live in the loan editor) the "Stand" button in the header.
    @ViewBuilder private var amountControls: some View {
        if manual != nil {
            if compact {
                Button("Stand neu setzen …") { model.openLoanEditor(.anchor, accountId: account.id) }
                    .buttonStyle(.borderless).appFont(.caption)
            }
        } else if editing {
            editor
        } else {
            Button(initial == nil ? "Betrag eingeben" : "Ursprünglich: \(Money.format(initial!))") {
                text = initial.map { Money.plain($0) } ?? ""
                editing = true
            }
            .buttonStyle(.borderless).appFont(.caption)
            .sensitive(initial == nil ? [] : .amounts) // the original loan amount
            .help("Ursprünglicher Kreditbetrag bearbeiten")
        }
    }
}

private struct CardIf: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.card() } else { content }
    }
}
