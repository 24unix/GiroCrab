import SwiftUI
import Charts
import GiroCrabCore

/// Header card of the stream: title, balance, calm balance chart and the
/// monthly KPIs (consumption is always shown without ETF plans / perks).
struct StreamHeaderCard: View {
    @Environment(AppModel.self) private var model

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

            if model.scope != .investments {
                BalanceChart(points: model.history)
                    .frame(height: 86)
            }

            HStack(spacing: 10) {
                KPI(title: "Konsumausgaben", subtitle: "diesen Monat", value: Money.format(-model.consumptionThisMonth), tint: Theme.outflow)
                KPI(title: "Investiert", subtitle: "Sparpläne & Perks", value: Money.format(model.investedThisMonth), tint: Theme.invest)
                KPI(title: "Einnahmen", subtitle: "diesen Monat", value: Money.format(model.incomeThisMonth), tint: Theme.inflow)
            }

            HStack(spacing: 12) {
                Menu {
                    Picker("Zeitraum", selection: $model.period) {
                        ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(model.period.rawValue, systemImage: "calendar")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Menu {
                    Picker("Status", selection: $model.statusFilter) {
                        ForEach(StatusFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Status: \(model.statusFilter.rawValue)", systemImage: "line.3.horizontal.decrease")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
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
    let title: String
    let subtitle: String
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

    private struct Point: Identifiable {
        let id: Int
        let date: Date
        let euros: Double // display only; data stays in cents
    }

    var body: some View {
        let pts: [Point] = points.enumerated().compactMap { i, p in
            DateText.date(p.date).map { Point(id: i, date: $0, euros: Double(p.balanceCents) / 100) }
        }
        let minV = pts.map(\.euros).min() ?? 0
        let maxV = pts.map(\.euros).max() ?? 1
        let pad = max((maxV - minV) * 0.15, 1)
        Chart(pts) { p in
            AreaMark(x: .value("Tag", p.date, unit: .day), yStart: .value("Min", minV - pad), yEnd: .value("Saldo", p.euros))
                .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.14), Theme.accent.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Tag", p.date, unit: .day), y: .value("Saldo", p.euros))
                .foregroundStyle(Theme.accent.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
        }
        .chartYScale(domain: (minV - pad)...(maxV + pad))
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated), anchor: .top)
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }
}
