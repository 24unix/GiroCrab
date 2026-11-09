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

    private var initial: Int64? { account.initialBalanceCents.map { abs($0) }.flatMap { $0 > 0 ? $0 : nil } }
    private var repaid: Double? {
        guard let p = initial else { return nil }
        return max(0, min(1, 1 - Double(abs(account.balanceCents)) / Double(p)))
    }

    /// "280.000,50" / "280000.5" / "280000" -> cents (Decimal, never Double).
    private static func parseCents(_ s: String) -> Int64? {
        var t = s.replacingOccurrences(of: "€", with: "").replacingOccurrences(of: " ", with: "")
        if t.contains(",") { t = t.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".") }
        guard let d = Decimal(string: t, locale: Locale(identifier: "en_US")), d > 0 else { return nil }
        return NSDecimalNumber(decimal: d * 100).rounding(accordingToBehavior: nil).int64Value
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            model.setAccountInitialBalance(account.id, cents: nil)
        } else if let c = Self.parseCents(trimmed) {
            model.setAccountInitialBalance(account.id, cents: c)
        }
        editing = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if !compact { Label("Tilgung", systemImage: "house").font(.headline) }
                if let repaid {
                    Text(String(format: "%.0f %% getilgt", repaid * 100)).font(.callout.weight(.semibold)).foregroundStyle(Theme.loan)
                } else {
                    Text("Ursprünglicher Kreditbetrag fehlt").font(.caption).foregroundStyle(Theme.secondary)
                }
                Spacer()
                if editing {
                    TextField("z. B. 280.000,00", text: $text)
                        .textFieldStyle(.roundedBorder).frame(width: 130).onSubmit(commit)
                    Button("OK", action: commit).controlSize(.small)
                } else {
                    Button(initial == nil ? "Betrag eingeben" : "Ursprünglich: \(Money.format(initial!))") {
                        text = initial.map { Money.plain($0) } ?? ""
                        editing = true
                    }
                    .buttonStyle(.link).font(.caption)
                    .help("Ursprünglicher Kreditbetrag bearbeiten")
                }
            }
            if let repaid {
                ProgressView(value: repaid).progressViewStyle(.linear).tint(Theme.loan)
            }
        }
        .modifier(CardIf(enabled: !compact))
    }
}

private struct CardIf: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.card() } else { content }
    }
}
