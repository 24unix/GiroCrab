import SwiftUI
import Charts
import GiroCrabCore

/// Monthly sums of the selected category (incl. subcategories) above its bookings (GitHub #502).
/// Pure expense categories are drawn upwards (magnitude), mixed ones signed.
struct CategorySumChart: View {
    let sums: [CategoryPeriodSum]
    @State private var selected: Date?
    @Environment(\.textScale) private var textScale

    struct Bar: Identifiable, Equatable {
        let start: Date
        let cents: Int64
        var id: Date { start }
    }

    static func bars(_ sums: [CategoryPeriodSum]) -> [Bar] {
        sums.compactMap { s in
            DateText.date(s.period + "-01").map { Bar(start: $0, cents: s.cents) }
        }
    }

    /// Expense-only series is shown as positive heights.
    static func flipsSign(_ bars: [Bar]) -> Bool {
        !bars.isEmpty && bars.allSatisfy { $0.cents <= 0 }
    }

    private func height(_ b: Bar, flip: Bool) -> Double {
        Double(flip ? -b.cents : b.cents) / 100
    }

    var body: some View {
        let bars = Self.bars(sums)
        let flip = Self.flipsSign(bars)
        if bars.isEmpty {
            Color.clear
        } else {
            let hit = selected.flatMap { d in
                bars.first { Calendar.current.isDate($0.start, equalTo: d, toGranularity: .month) }
            }
            Chart {
                ForEach(bars) { b in
                    BarMark(x: .value("Monat", b.start, unit: .month), y: .value("Summe", height(b, flip: flip)))
                        .foregroundStyle(b.cents < 0 && !flip ? Theme.outflow : (b.cents < 0 ? Theme.accent : Theme.inflow))
                        .opacity(hit == nil || hit == b ? 0.85 : 0.35)
                        .cornerRadius(1.5)
                }
                if let h = hit {
                    RuleMark(x: .value("Monat", h.start, unit: .month))
                        .foregroundStyle(.clear)
                        .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            VStack(spacing: 1) {
                                Text(h.start, format: .dateTime.month(.wide).year())
                                    .appFont(.caption2).foregroundStyle(Theme.secondary)
                                Text(verbatim: Money.format(h.cents))
                                    .sensitive()
                                    .appFont(.caption, weight: .semibold, monospacedDigit: true)
                                    .foregroundStyle(h.cents < 0 ? Theme.outflow : Theme.text)
                            }
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                        }
                }
            }
            .chartXSelection(value: $selected)
            .chartYAxis {
                AxisMarks(position: .trailing) { v in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        .foregroundStyle(Theme.tertiary.opacity(0.45))
                    AxisValueLabel {
                        if let d = v.as(Double.self) {
                            Text(d, format: .currency(code: "EUR").precision(.fractionLength(0)))
                                .sensitive()
                                .appFont(.caption2, monospacedDigit: true)
                                .foregroundStyle(Theme.tertiary)
                                .fixedSize()
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { v in
                    AxisValueLabel(centered: true) {
                        if let d = v.as(Date.self) {
                            Text(d, format: .dateTime.month(.abbreviated).year(.twoDigits))
                                .appFont(.caption2).foregroundStyle(Theme.tertiary).fixedSize()
                        }
                    }
                }
            }
            .accessibilityLabel("Monatssummen der Kategorie")
        }
    }
}
