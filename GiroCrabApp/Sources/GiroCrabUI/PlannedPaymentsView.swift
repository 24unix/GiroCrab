import SwiftUI
import GiroCrabCore
#if os(macOS)
import AppKit
#endif

/// „Geplant“ (GitHub #240): everything already ordered at the bank but not
/// booked yet, across accounts. Only real orders – never guesses from the
/// booking history (those stay in the recurring-payments view).
struct PlannedPaymentsView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var listFocused: Bool

    private struct ReloadKey: Equatable {
        let account: Int64?
        let horizon: PlannedHorizon
        let version: Int
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Geplant").appFont(.title2, weight: .semibold)
                Text("Zahlungen, die bei der Bank bereits beauftragt, aber noch nicht gebucht sind.")
                    .appFont(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            HStack(spacing: 12) {
                Picker("Konto", selection: $model.plannedAccountFilter) {
                    Text("Alle Konten").tag(Int64?.none)
                    Divider()
                    ForEach(model.allAccounts) { a in
                        Label(a.name, systemImage: a.sfSymbol).tag(Int64?.some(a.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .sensitive(model.plannedAccountFilter == nil ? [] : .personal) // the selected account's name
                .frame(minWidth: 150, maxWidth: 240)
                Picker("Zeitraum", selection: $model.plannedHorizon) {
                    ForEach(PlannedHorizon.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 140)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            totals.padding(.horizontal, 20)
            if model.plannedPayments.isEmpty {
                ContentUnavailableView(
                    "Keine geplanten Zahlungen",
                    systemImage: "calendar.badge.clock",
                    description: Text("Terminüberweisungen und Daueraufträge deiner Bank erscheinen hier bis zur Ausführung."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.plannedMonths) { month in
                                monthHeader(month)
                                    .padding(.top, 14)
                                ForEach(Array(month.items.enumerated()), id: \.element.id) { index, p in
                                    PlannedRow(payment: p, isLast: index == month.items.count - 1)
                                        .id(p.id)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 18)
                    }
                    // Keyboard like the booking list: ↑/↓ move the selection, which
                    // scrolls into view; a click on a row gives the list the focus.
                    .focusable()
                    .focusEffectDisabled()
                    .focused($listFocused)
                    .onKeyPress(.downArrow) { model.movePlannedSelection(1); return .handled }
                    .onKeyPress(.upArrow) { model.movePlannedSelection(-1); return .handled }
                    .onKeyPress(.escape) {
                        guard model.selectedPlannedID != nil else { return .ignored }
                        model.selectedPlannedID = nil
                        return .handled
                    }
                    .onChange(of: model.selectedPlannedID) { _, id in
                        listFocused = true
                        guard let id else { return }
                        withAnimation(Motion.animation(.easeOut(duration: 0.15))) { proxy.scrollTo(id) }
                    }
                    .onAppear { listFocused = model.options.screenshotPath == nil }
                }
            }
        }
        .padding(.top, 16)
        .background(Theme.canvas)
        .task(id: ReloadKey(account: model.plannedAccountFilter, horizon: model.plannedHorizon, version: model.plannedVersion)) {
            await model.reloadPlanned()
        }
    }

    private var totals: some View {
        HStack(spacing: 24) {
            totalCell("Abgehend", model.plannedTotals.outgoingCents)
            totalCell("Eingehend", model.plannedTotals.incomingCents)
            Spacer(minLength: 0)
        }
        .card(padding: 12)
    }

    private func totalCell(_ label: LocalizedStringKey, _ cents: Int64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).appFont(.caption).foregroundStyle(Theme.secondary)
            Text(Money.format(cents)).appFont(.title3, weight: .semibold, monospacedDigit: true)
                .fixedSize().sensitive()
        }
    }

    /// Top of a month card, like the day header of the booking stream.
    private func monthHeader(_ month: PlannedMonth) -> some View {
        let sum = month.sumCents
        return VStack(spacing: 0) {
            HStack {
                Text(DateText.date(month.id + "-01")?.formatted(.dateTime.month(.wide).year()) ?? month.id)
                    .appFont(.subheadline, weight: .semibold)
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(Money.signed(sum))
                    .sensitive()
                    .appFont(.subheadline, monospacedDigit: true)
                    .foregroundStyle(sum > 0 ? Theme.inflow : Theme.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Rectangle().fill(Theme.border).frame(height: 1)
        }
        .modifier(DayCardSegment(isTop: true, isBottom: false))
    }
}

/// One planned payment as a slice of a month card (same look as a booking row).
private struct PlannedRow: View {
    @Environment(AppModel.self) private var model
    let payment: PlannedPayment
    let isLast: Bool

    var body: some View {
        let p = payment
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: p.kindSymbol)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.accent.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.counterparty).appFont(.body, weight: .medium).lineLimit(1).sensitive()
                    Text(p.purpose.isEmpty ? p.accountName : "\(p.purpose) · \(p.accountName)")
                        .appFont(.callout).foregroundStyle(Theme.secondary).lineLimit(1).sensitive()
                    Text(p.kindText).appFont(.caption).foregroundStyle(Theme.tertiary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    AmountLabel(cents: p.amountCents).lineLimit(1).fixedSize()
                    Text(DateText.medium(p.date)).appFont(.caption, monospacedDigit: true).foregroundStyle(Theme.secondary)
                }
            }
            .frame(minHeight: 44, alignment: .top)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(model.selectedPlannedID == p.id ? Theme.selection : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture { model.selectedPlannedID = p.id }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(model.selectedPlannedID == p.id ? [.isButton, .isSelected] : .isButton)
            .contextMenu { PlannedActions(payment: p) }
            if !isLast {
                Rectangle().fill(Theme.border.opacity(0.7)).frame(height: 1).padding(.leading, 64)
            }
        }
        .modifier(DayCardSegment(isTop: false, isBottom: isLast))
    }
}

extension PlannedPayment {
    var kindSymbol: String {
        switch kind {
        case .standingOrder: "repeat"
        case .directDebit: "arrow.down.circle"
        case .scheduledTransfer: "calendar.badge.clock"
        }
    }

    /// "Terminüberweisung", "Lastschrift" or "Dauerauftrag · monatlich".
    var kindText: String {
        if kind == .directDebit { return String(localized: "Lastschrift") }
        guard kind == .standingOrder else { return String(localized: "Terminüberweisung") }
        return String(localized: "Dauerauftrag") + " · " + rhythmText
    }

    /// How often a standing order runs, in words.
    var rhythmText: String {
        let n = Int(rhythmInterval)
        if rhythmUnit == "W" {
            return n <= 1 ? String(localized: "wöchentlich") : String(localized: "alle \(n) Wochen")
        }
        switch n {
        case ...1: return String(localized: "monatlich")
        case 3: return String(localized: "vierteljährlich")
        case 6: return String(localized: "halbjährlich")
        case 12: return String(localized: "jährlich")
        default: return String(localized: "alle \(n) Monate")
        }
    }
}

/// Actions on one planned payment (context menu and inspector).
struct PlannedActions: View {
    @Environment(AppModel.self) private var model
    let payment: PlannedPayment

    var body: some View {
        Button("Konto anzeigen", systemImage: "building.columns") {
            model.sidebarSelection = .account(payment.accountId)
        }
        if !payment.counterpartyIban.isEmpty {
            Button("IBAN kopieren", systemImage: "doc.on.doc") {
                #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(payment.counterpartyIban, forType: .string)
                #else
                UIPasteboard.general.string = payment.counterpartyIban
                #endif
            }
        }
    }
}

/// Inspector of „Geplant“: details of the selected payment (HIG: an inspector
/// shows the selection, never a leftover from another list).
struct PlannedInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let p = model.plannedPayments.first(where: { $0.id == model.selectedPlannedID }) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(p.counterparty).appFont(.title3, weight: .semibold).sensitive()
                    Text(Money.format(p.amountCents))
                        .appFont(.title, weight: .semibold, monospacedDigit: true)
                        .foregroundStyle(p.amountCents < 0 ? Theme.negative : Theme.invest)
                        .fixedSize().sensitive()
                    Text(p.kindText).appFont(.callout).foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
                VStack(alignment: .leading, spacing: 10) {
                    field("Ausführung", DateText.medium(p.date), sensitive: false)
                    field("Konto", p.accountName)
                    if !p.counterpartyIban.isEmpty { field("IBAN", p.counterpartyIban, mono: true) }
                    if !p.purpose.isEmpty { field("Verwendungszweck", p.purpose) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
                HStack { PlannedActions(payment: p) }
                    .buttonStyle(.bordered)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Label("Keine Zahlung ausgewählt", systemImage: "calendar.badge.clock")
                    .appFont(.headline)
                Text("Wählen Sie eine geplante Zahlung, um Details zu sehen.")
                    .appFont(.callout).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    @ViewBuilder
    private func field(_ label: LocalizedStringKey, _ value: String, mono: Bool = false, sensitive: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).appFont(.caption).foregroundStyle(Theme.secondary)
            let t = Text(value).appFont(.callout, monospacedDigit: mono).textSelection(.enabled)
            if sensitive { t.sensitive() } else { t }
        }
    }
}
