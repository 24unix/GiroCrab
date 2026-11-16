import SwiftUI
import Charts
import GiroCrabCore

/// Day, month, quarter or year sums of the selected category (incl. subcategories) above its
/// bookings (GitHub #502, #557, #634). Pure expense categories are drawn upwards (magnitude),
/// mixed ones signed. Bars or a line, following the header's chart type.
struct CategorySumChart: View {
    let sums: [CategoryPeriodSum]
    @State private var selected: Date?
    @Environment(\.textScale) private var textScale
    @Environment(AppModel.self) private var model
    @AppStorage(BalanceChartStyle.defaultsKey) private var style: BalanceChartStyle = .line

    struct Bar: Identifiable, Equatable {
        let start: Date
        /// First day after the bar.
        let end: Date
        let cents: Int64
        var id: Date { start }
        var mid: Date { start.addingTimeInterval(end.timeIntervalSince(start) / 2) }
    }

    /// `period` is `yyyy` (year), `yyyy-MM` (month) or `yyyy-MM-dd` (day); with `.quarter`
    /// the months are folded into quarters first.
    static func bars(_ sums: [CategoryPeriodSum], unit: BalanceBarUnit = .month) -> [Bar] {
        let quarterly = unit == .quarter
        return (quarterly ? quarters(sums) : sums).compactMap { s in
            let (iso, step): (String, DateComponents) = switch s.period.count {
            case 4: (s.period + "-01-01", DateComponents(year: 1))
            case 7: (s.period + "-01", DateComponents(month: quarterly ? 3 : 1))
            default: (s.period, DateComponents(day: 1))
            }
            guard let start = DateText.date(iso), let end = Calendar.current.date(byAdding: step, to: start) else { return nil }
            return Bar(start: start, end: end, cents: s.cents)
        }
    }

    /// Month sums (`yyyy-MM`, oldest first) added up per quarter, keyed by its first month.
    static func quarters(_ months: [CategoryPeriodSum]) -> [CategoryPeriodSum] {
        var out: [CategoryPeriodSum] = []
        for m in months {
            guard m.period.count == 7, let month = Int(m.period.suffix(2)), (1...12).contains(month) else { continue }
            let key = "\(m.period.prefix(4))-" + String(format: "%02d", (month - 1) / 3 * 3 + 1)
            if let last = out.last, last.period == key {
                out[out.count - 1] = CategoryPeriodSum(period: key, cents: last.cents + m.cents)
            } else {
                out.append(CategoryPeriodSum(period: key, cents: m.cents))
            }
        }
        return out
    }

    /// Calendar unit of one bar (`.automatic` counts as months, like the model's fallback).
    static func component(_ unit: BalanceBarUnit) -> Calendar.Component {
        unit == .automatic ? .month : unit.calendarComponent
    }

    /// Expense-only series is shown as positive heights.
    static func flipsSign(_ bars: [Bar]) -> Bool {
        !bars.isEmpty && bars.allSatisfy { $0.cents <= 0 }
    }

    /// At most `count` axis labels, one per shown bar (no repeated quarter labels).
    static func axisDates(_ bars: [Bar], count: Int = 6) -> [Date] {
        guard !bars.isEmpty else { return [] }
        let every = max(1, Int((Double(bars.count) / Double(count)).rounded(.up)))
        return stride(from: 0, to: bars.count, by: every).map { bars[$0].mid }
    }

    private func height(_ b: Bar, flip: Bool) -> Double {
        Double(flip ? -b.cents : b.cents) / 100
    }

    /// Gap between neighbouring bars.
    private func inset(_ b: Bar) -> TimeInterval { b.end.timeIntervalSince(b.start) * 0.12 }

    var body: some View {
        let choice = model.effectiveCategoryBarUnit
        let bars = Self.bars(sums, unit: choice)
        let unit = Self.component(choice)
        let flip = Self.flipsSign(bars)
        let line = style == .line
        if bars.isEmpty {
            Color.clear
        } else {
            let hit = selected.flatMap { d in bars.first { $0.start <= d && d < $0.end } }
            Chart {
                ForEach(bars) { b in
                    if line {
                        LineMark(x: .value("Zeitraum", b.mid), y: .value("Summe", height(b, flip: flip)))
                            .foregroundStyle(Theme.accent.opacity(0.8))
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .interpolationMethod(.monotone)
                        PointMark(x: .value("Zeitraum", b.mid), y: .value("Summe", height(b, flip: flip)))
                            .foregroundStyle(b.cents < 0 && !flip ? Theme.outflow : Theme.accent)
                            .symbolSize(hit == b ? 36 : 10)
                    } else {
                        RectangleMark(xStart: .value("Zeitraum", b.start.addingTimeInterval(inset(b))),
                                      xEnd: .value("Zeitraum", b.end.addingTimeInterval(-inset(b))),
                                      yStart: .value("Summe", 0.0), yEnd: .value("Summe", height(b, flip: flip)))
                            .foregroundStyle(b.cents < 0 && !flip ? Theme.outflow : (b.cents < 0 ? Theme.accent : Theme.inflow))
                            .opacity(hit == nil || hit == b ? 0.85 : 0.35)
                            .cornerRadius(1.5)
                    }
                }
                if let h = hit {
                    RuleMark(x: .value("Zeitraum", h.mid))
                        .foregroundStyle(line ? Theme.secondary.opacity(0.45) : .clear)
                        .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            VStack(spacing: 1) {
                                Text(h.start, format: Self.tooltipFormat(unit))
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
                AxisMarks(values: Self.axisDates(bars)) { v in
                    AxisValueLabel(anchor: .top) {
                        if let d = v.as(Date.self) {
                            Text(d, format: Self.axisFormat(unit))
                                .appFont(.caption2).foregroundStyle(Theme.tertiary).fixedSize()
                        }
                    }
                }
            }
            .accessibilityLabel("Summen der Kategorie")
            .accessibilityChartDescriptor(Descriptor(bars: bars, unit: unit, flip: flip))
            .contextMenu {
                ChartStyleInlinePicker()
                unitPicker
            }
        }
    }

    /// Audio Graph of the drawn bars (flipped heights included). Built only when
    /// assistive technology asks, not on every hover re-render.
    struct Descriptor: AXChartDescriptorRepresentable {
        let bars: [Bar]
        let unit: Calendar.Component
        let flip: Bool

        func makeChartDescriptor() -> AXChartDescriptor {
            let summary = switch (unit, flip) {
            case (.day, false): String(localized: "Summe je Tag")
            case (.day, true): String(localized: "Ausgaben je Tag")
            case (.year, false): String(localized: "Summe je Jahr")
            case (.year, true): String(localized: "Ausgaben je Jahr")
            case (.quarter, false): String(localized: "Summe je Quartal")
            case (.quarter, true): String(localized: "Ausgaben je Quartal")
            case (_, false): String(localized: "Summe je Monat")
            case (_, true): String(localized: "Ausgaben je Monat")
            }
            let name = flip ? String(localized: "Ausgaben") : String(localized: "Summe")
            return BarChartDescriptor(
                title: String(localized: "Summen der Kategorie"),
                summary: summary,
                categoryTitle: String(localized: "Zeitraum"),
                categories: bars.map { $0.start.formatted(CategorySumChart.tooltipFormat(unit)) },
                valueTitle: name,
                series: [.init(name: name, values: bars.map { Double(flip ? -$0.cents : $0.cents) / 100 })]
            ).makeChartDescriptor()
        }
    }

    static func tooltipFormat(_ unit: Calendar.Component) -> Date.FormatStyle {
        switch unit {
        case .year: .dateTime.year()
        case .quarter: .dateTime.quarter().year()
        case .day: .dateTime.day().month(.abbreviated).year()
        default: .dateTime.month(.wide).year()
        }
    }

    static func axisFormat(_ unit: Calendar.Component) -> Date.FormatStyle {
        switch unit {
        case .year: .dateTime.year()
        case .quarter: .dateTime.quarter().year(.twoDigits)
        case .day: .dateTime.day().month(.abbreviated)
        default: .dateTime.month(.abbreviated).year(.twoDigits)
        }
    }

    private var unitSelection: Binding<BalanceBarUnit> {
        Binding(get: { model.effectiveCategoryBarUnit },
                set: { model.categoryBarUnit = $0; model.reloadCategoryHistory() })
    }

    /// Day / month / quarter / year per bar, right on the chart (#557, #634).
    private var unitPicker: some View {
        Picker("Balken je", selection: unitSelection) {
            ForEach(BalanceBarUnit.categoryCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
    }
}
