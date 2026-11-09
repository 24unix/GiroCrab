import SwiftUI
import Charts
import GiroCrabCore

/// "Sparpläne & Perks": savings-plan execution grid, Trade Republic perks,
/// and consumption vs. investment per month. Investments never count as
/// "Konsumausgaben".
struct InvestmentDashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let d = model.dashboard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    KPI(title: "Monatlich investiert", subtitle: "\(d.plans.filter(\.active).count) aktive Sparpläne", value: Money.format(d.totalMonthlyCents), tint: Theme.invest)
                    KPI(title: "Saveback (1 %)", subtitle: "\(d.savebackCount)× gutgeschrieben", value: Money.format(d.savebackEarnedCents), tint: Theme.inflow)
                    KPI(title: "Round up", subtitle: "\(d.roundupCount)× investiert", value: Money.format(d.roundupInvestedCents), tint: Theme.invest)
                }
                PlanGrid(dashboard: d)
                PerksCard(dashboard: d)
                FlowChartCard(dashboard: d)
                Text("Investment-Buchungen").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondary).padding(.top, 4)
            }
        }
    }
}

struct PlanGrid: View {
    let dashboard: InvestmentDashboard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Monatliche Sparpläne").font(.subheadline.weight(.semibold))
                Spacer()
                Text("Ausführungen der letzten \(dashboard.months.count) Monate").font(.caption).foregroundStyle(Theme.secondary)
            }
            .padding(.bottom, 10)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
                GridRow {
                    Text("Plan").gridColumnAlignment(.leading)
                    ForEach(dashboard.months, id: \.self) { m in
                        Text(DateText.monthLabel(m)).frame(width: 40)
                    }
                    Text("pro Monat").gridColumnAlignment(.trailing)
                }
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
                .padding(.bottom, 6)
                ForEach(dashboard.plans) { plan in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        HStack(spacing: 8) {
                            MerchantSignet(merchant: plan.merchant, size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(plan.merchant.name).font(.callout.weight(.medium)).lineLimit(1)
                                Text(planSubtitle(plan)).font(.caption2.monospaced()).foregroundStyle(Theme.secondary).lineLimit(1)
                            }
                        }
                        ForEach(plan.executions, id: \.month) { e in
                            ZStack {
                                if e.amountCents > 0 {
                                    Circle().fill(Theme.invest.opacity(0.85)).frame(width: 12, height: 12)
                                } else {
                                    Circle().strokeBorder(Theme.border, lineWidth: 1.5).frame(width: 12, height: 12)
                                }
                            }
                            .frame(width: 40)
                            .help(e.amountCents > 0 ? "\(DateText.monthLabel(e.month)): \(Money.format(e.amountCents))" : "nicht ausgeführt")
                        }
                        Text(Money.format(plan.monthlyCents))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(plan.active ? Theme.text : Theme.tertiary)
                    }
                    .padding(.vertical, 7)
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text("Summe aktive Pläne").font(.callout.weight(.semibold))
                    ForEach(dashboard.months, id: \.self) { _ in Color.clear.frame(width: 40, height: 1) }
                    Text(Money.format(dashboard.totalMonthlyCents)).font(.callout.weight(.semibold).monospacedDigit())
                }
                .padding(.top, 8)
            }
        }
        .card()
    }

    private func planSubtitle(_ p: SavingsPlan) -> String {
        var parts: [String] = []
        if !p.merchant.isin.isEmpty { parts.append(p.merchant.isin) }
        if !p.merchant.wkn.isEmpty { parts.append("WKN \(p.merchant.wkn)") }
        if parts.isEmpty { parts.append(p.merchant.assetClass.isEmpty ? "Sparplan" : p.merchant.assetClass) }
        parts.append("am \(p.dayOfMonth).")
        return parts.joined(separator: " · ")
    }
}

struct PerksCard: View {
    let dashboard: InvestmentDashboard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Trade Republic Perks", systemImage: "gift").font(.subheadline.weight(.semibold))
                Spacer()
                Text("diesen Monat \(Money.format(dashboard.perksThisMonthCents))").font(.caption).foregroundStyle(Theme.secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                perk(title: "1 % Saveback", value: dashboard.savebackEarnedCents, count: dashboard.savebackCount,
                     text: "Bonus auf Kartenzahlungen, automatisch in den Sparplan investiert.")
                perk(title: "Round up", value: dashboard.roundupInvestedCents, count: dashboard.roundupCount,
                     text: "Aufgerundete Cent-Beträge jeder Kartenzahlung, monatlich investiert.")
            }
        }
        .card()
    }

    private func perk(title: String, value: Int64, count: UInt32, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(Theme.secondary)
            Text(Money.format(value)).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.invest)
            Text("\(count) Ausführungen").font(.caption2).foregroundStyle(Theme.tertiary)
            Text(text).font(.caption2).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.canvas))
    }
}

struct FlowChartCard: View {
    let dashboard: InvestmentDashboard

    private struct Bar: Identifiable {
        let id = UUID()
        let month: String
        let kind: String
        let euros: Double
    }

    var body: some View {
        let bars = dashboard.monthly.flatMap { m in
            [Bar(month: DateText.monthLabel(m.month), kind: "Konsum", euros: Double(m.consumptionCents) / 100),
             Bar(month: DateText.monthLabel(m.month), kind: "Investiert", euros: Double(m.investmentCents) / 100)]
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("Konsum vs. Investition").font(.subheadline.weight(.semibold))
            Chart(bars) { b in
                BarMark(x: .value("Monat", b.month), y: .value("€", b.euros))
                    .foregroundStyle(by: .value("Art", b.kind))
                    .position(by: .value("Art", b.kind))
            }
            .chartForegroundStyleScale(["Konsum": Theme.tertiary, "Investiert": Theme.invest])
            .chartYAxis { AxisMarks(position: .leading) { AxisGridLine().foregroundStyle(Theme.border) ; AxisValueLabel() } }
            .frame(height: 140)
        }
        .card()
    }
}
