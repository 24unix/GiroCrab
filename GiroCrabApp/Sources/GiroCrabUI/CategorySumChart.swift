import SwiftUI
import Charts
import GiroCrabCore

/// Day, month or year sums of the selected category (incl. subcategories) above its bookings (GitHub #502, #557).
/// Pure expense categories are drawn upwards (magnitude), mixed ones signed.
struct CategorySumChart: View {
    let sums: [CategoryPeriodSum]
    @State private var selected: Date?
    @Environment(\.textScale) private var textScale
    @Environment(AppModel.self) private var model

    struct Bar: Identifiable, Equatable {
        let start: Date
        let cents: Int64
        var id: Date { start }
    }

    /// `period` is `yyyy` (year), `yyyy-MM` (month) or `yyyy-MM-dd` (day).
    static func bars(_ sums: [CategoryPeriodSum]) -> [Bar] {
        sums.compactMap { s in
            let iso: String = switch s.period.count {
            case 4: s.period + "-01-01"
            case 7: s.period + "-01"
            default: s.period
            }
            return DateText.date(iso).map { Bar(start: $0, cents: s.cents) }
        }
    }

    /// Calendar unit of one bar (`.automatic` counts as months, like the model's fallback).
    static func component(_ unit: BalanceBarUnit) -> Calendar.Component {
        unit == .automatic ? .month : unit.calendarComponent
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
        let unit = Self.component(model.effectiveCategoryBarUnit)
        let flip = Self.flipsSign(bars)
        if bars.isEmpty {
            Color.clear
        } else {
            let hit = selected.flatMap { d in
                bars.first { Calendar.current.isDate($0.start, equalTo: d, toGranularity: unit) }
            }
            Chart {
                ForEach(bars) { b in
                    BarMark(x: .value("Zeitraum", b.start, unit: unit), y: .value("Summe", height(b, flip: flip)))
                        .foregroundStyle(b.cents < 0 && !flip ? Theme.outflow : (b.cents < 0 ? Theme.accent : Theme.inflow))
                        .opacity(hit == nil || hit == b ? 0.85 : 0.35)
                        .cornerRadius(1.5)
                }
                if let h = hit {
                    RuleMark(x: .value("Zeitraum", h.start, unit: unit))
                        .foregroundStyle(.clear)
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
                AxisMarks(values: .automatic(desiredCount: 6)) { v in
                    AxisValueLabel(centered: true) {
                        if let d = v.as(Date.self) {
                            Text(d, format: Self.axisFormat(unit))
                                .appFont(.caption2).foregroundStyle(Theme.tertiary).fixedSize()
                        }
                    }
                }
            }
            .accessibilityLabel("Summen der Kategorie")
            .accessibilityChartDescriptor(Descriptor(bars: bars, unit: unit, flip: flip))
            .overlay(alignment: .topLeading) { unitMenu }
            .contextMenu { unitPicker }
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
        case .day: .dateTime.day().month(.abbreviated).year()
        default: .dateTime.month(.wide).year()
        }
    }

    static func axisFormat(_ unit: Calendar.Component) -> Date.FormatStyle {
        switch unit {
        case .year: .dateTime.year()
        case .day: .dateTime.day().month(.abbreviated)
        default: .dateTime.month(.abbreviated).year(.twoDigits)
        }
    }

    /// Day / month / year per bar, right on the chart (#557).
    private var unitPicker: some View {
        @Bindable var model = model
        return Picker("Balken je", selection: Binding(
            get: { model.effectiveCategoryBarUnit },
            set: { model.categoryBarUnit = $0; model.reloadCategoryHistory() }
        )) {
            ForEach([BalanceBarUnit.day, .month, .year]) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
    }

    private var unitMenu: some View {
        Menu { unitPicker } label: {
            Text(model.effectiveCategoryBarUnit.title)
                .appFont(.caption2).foregroundStyle(Theme.secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Balken je")
    }
}
