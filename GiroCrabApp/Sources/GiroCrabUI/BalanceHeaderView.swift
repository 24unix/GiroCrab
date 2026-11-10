import SwiftUI
import Charts
import GiroCrabCore

/// Securities positions of a depot account (from the last sync).
struct HoldingsCard: View {
    @Environment(AppModel.self) private var model
    let account: Account
    @State private var holdings: [Holding] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !holdings.isEmpty {
                Text("Positionen").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
            }
            ForEach(holdings.indices, id: \.self) { i in
                let h = holdings[i]
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(h.name.isEmpty ? (h.isin.isEmpty ? h.wkn : h.isin) : h.name).lineLimit(1)
                        Text("\(h.quantity.formatted(.number.precision(.fractionLength(0...4)))) × \(Money.format(h.currentPriceCents)) · \(h.isin.isEmpty ? h.wkn : h.isin)")
                            .font(.caption2).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(Money.format(h.valueCents)).monospacedDigit()
                }
                .font(.callout)
            }
        }
        .task(id: "\(account.id)-\(account.balanceCents)-\(account.balanceDate)") {
            holdings = model.holdings(for: account.id)
        }
    }
}

/// Header card of the stream: title, balance, calm balance chart and the
/// monthly KPIs (consumption is always shown without ETF plans / perks).
struct StreamHeaderCard: View {
    @Environment(AppModel.self) private var model
    @State private var showDocuments = false

    private var account: Account? {
        if case .account(let id) = model.sidebarSelection { return model.account(for: id) }
        return nil
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.title).font(.title2.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Group {
                        if let a = account {
                            Text([a.bankName, a.iban.isEmpty ? "" : formatIBAN(a.iban)].filter { !$0.isEmpty }.joined(separator: " · "))
                        } else {
                            Text(model.lastSyncText)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                }
                Spacer()
                if let hb = model.headerBalance {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Money.format(hb.cents))
                            .font(.system(size: 26, weight: .semibold).monospacedDigit())
                            .foregroundStyle(account?.kind == .loan ? Theme.loan : Theme.text)
                        Text(hb.label).font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
            }

            if let a = account, a.kind == .loan {
                LoanProgressCard(account: a, compact: true)
            }

            if let a = account, a.kind == .brokerage {
                HoldingsCard(account: a)
            }

            if model.scope != .investments {
                BalanceChart(points: model.history) { model.jumpToDay($0) }
                    .frame(height: 86)
            }

            HStack(spacing: 10) {
                KPI(title: "Konsumausgaben", subtitle: "diesen Monat", value: Money.format(-model.consumptionThisMonth), tint: Theme.outflow)
                KPI(title: "Investiert", subtitle: "Sparpläne & Perks", value: Money.format(model.investedThisMonth), tint: Theme.invest)
                KPI(title: "Einnahmen", subtitle: "diesen Monat", value: Money.format(model.incomeThisMonth), tint: Theme.inflow)
            }

            HStack(spacing: 12) {
                PeriodQuickPicker()
                Menu {
                    Picker("Zeitraum", selection: $model.period) {
                        ForEach(Period.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(model.period.title, systemImage: "calendar")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Menu {
                    Picker("Status", selection: $model.statusFilter) {
                        ForEach(StatusFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Status: \(model.statusFilter.title)", systemImage: "line.3.horizontal.decrease")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                if let a = account {
                    Button { showDocuments = true } label: {
                        Label("Dokumente", systemImage: "doc.text")
                    }
                    .buttonStyle(.borderless)
                    .sheet(isPresented: $showDocuments) { AccountDocumentsSheet(account: a) }
                }
                Spacer()
                Text("\(model.visibleBookings.count) Buchungen")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            .font(.caption)
            .foregroundStyle(Theme.secondary)
        }
        .card()
    }
}

struct KPI: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(Theme.secondary)
            Text(value).font(.system(size: 16, weight: .semibold).monospacedDigit()).foregroundStyle(tint)
            Text(subtitle).font(.caption2).foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
}

struct BalanceChart: View {
    let points: [DailyBalance]
    /// Click on a day (jump to its bookings).
    var onSelect: ((Date) -> Void)? = nil
    /// Day under the mouse pointer (hover readout: date + balance).
    @State private var hovered: Point?

    private struct Point: Identifiable, Equatable {
        let id: Int
        let date: Date
        let cents: Int64
        var euros: Double { Double(cents) / 100 } // display only; data stays in cents
    }

    var body: some View {
        let pts: [Point] = points.enumerated().compactMap { i, p in
            DateText.date(p.date).map { Point(id: i, date: $0, cents: p.balanceCents) }
        }
        let minV = pts.map(\.euros).min() ?? 0
        let maxV = pts.map(\.euros).max() ?? 1
        let pad = max((maxV - minV) * 0.15, 1)
        Chart {
            ForEach(pts) { p in
                AreaMark(x: .value("Tag", p.date, unit: .day), yStart: .value("Min", minV - pad), yEnd: .value("Saldo", p.euros))
                    .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.14), Theme.accent.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Tag", p.date, unit: .day), y: .value("Saldo", p.euros))
                    .foregroundStyle(Theme.accent.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
            if let h = hovered {
                PointMark(x: .value("Tag", h.date, unit: .day), y: .value("Saldo", h.euros))
                    .foregroundStyle(Theme.accent)
                    .symbolSize(36)
                RuleMark(x: .value("Tag", h.date, unit: .day))
                    .foregroundStyle(Theme.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: h.id * 2 > pts.count ? .topLeading : .topTrailing, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        VStack(spacing: 1) {
                            Text(h.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
                                .font(.caption2)
                                .foregroundStyle(Theme.secondary)
                            Text(Money.format(h.cents))
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(h.cents < 0 ? Theme.outflow : Theme.text)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                    }
            }
        }
        .chartYScale(domain: (minV - pad)...(maxV + pad))
        .chartYAxis(.hidden)
        .chartXAxis {
            // long periods: one label per year, otherwise per month
            if let first = pts.first?.date, let last = pts.last?.date,
               last.timeIntervalSince(first) > 400 * 86_400 {
                AxisMarks(values: .stride(by: .year)) { _ in
                    AxisValueLabel(format: .dateTime.year(), anchor: .top)
                        .foregroundStyle(Theme.tertiary)
                }
            } else if let first = pts.first?.date, let last = pts.last?.date,
                      last.timeIntervalSince(first) < 62 * 86_400 {
                // short periods (this/last month): weekly day labels
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated), anchor: .top)
                        .foregroundStyle(Theme.tertiary)
                }
            } else {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated), anchor: .top)
                        .foregroundStyle(Theme.tertiary)
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plot = proxy.plotFrame else { return }
                            let x = location.x - geo[plot].origin.x
                            guard let date: Date = proxy.value(atX: x) else { return }
                            let nearest = pts.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                            if nearest != hovered { hovered = nearest }
                        case .ended:
                            hovered = nil
                        }
                    }
                    .onTapGesture { location in
                        guard let onSelect, let plot = proxy.plotFrame,
                              let date: Date = proxy.value(atX: location.x - geo[plot].origin.x),
                              let nearest = pts.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })
                        else { return }
                        onSelect(nearest.date)
                    }
            }
        }
        .onChange(of: points.first?.date) { _, _ in hovered = nil }
        .onChange(of: points.count) { _, _ in hovered = nil }
    }
}
