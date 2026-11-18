import SwiftUI
import GiroCrabCore

/// Which accounts a rule is restricted to (#562): an empty list means all
/// accounts. Pure helpers, so the editor and its tests share one rule set.
enum RuleAccountSelection {
    /// `id` joins the selection (once), kept in the order it was added.
    static func adding(_ id: Int64, to ids: [Int64]) -> [Int64] {
        ids.contains(id) ? ids : ids + [id]
    }

    static func removing(_ id: Int64, from ids: [Int64]) -> [Int64] {
        ids.filter { $0 != id }
    }
}

/// Lays its subviews out left to right and wraps to the next line (chips).
private struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, result.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}

/// Multi-select for a rule's accounts: removable chips plus a menu to add one.
struct RuleAccountPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var accountIds: [Int64]

    private var accountsById: [Int64: Account] {
        Dictionary(uniqueKeysWithValues: model.accountMenuSections.flatMap(\.accounts).map { ($0.id, $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Konten")
                Spacer()
                Menu {
                    ForEach(model.accountMenuSections) { section in
                        Section(section.title) {
                            ForEach(section.accounts.filter { !accountIds.contains($0.id) }) { a in
                                Button("\(a.bankName) – \(model.accountLabel(a))") {
                                    accountIds = RuleAccountSelection.adding(a.id, to: accountIds)
                                }
                            }
                        }
                    }
                } label: {
                    Label("Konto hinzufügen", systemImage: "plus.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if accountIds.isEmpty {
                Text("Alle Konten")
                    .appFont(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ChipFlowLayout {
                    ForEach(accountIds, id: \.self) { id in
                        chip(id)
                    }
                }
            }
        }
    }

    private func chip(_ id: Int64) -> some View {
        let account = accountsById[id]
        return HStack(spacing: 4) {
            Text(account.map { "\($0.bankName) – \($0.name)" } ?? "?")
                .appFont(.caption)
                .lineLimit(1)
                .sensitive()
            Button {
                accountIds = RuleAccountSelection.removing(id, from: accountIds)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Konto entfernen"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
    }
}
