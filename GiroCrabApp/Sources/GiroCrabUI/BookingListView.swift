import SwiftUI
import GiroCrabCore

/// Column 2: calm booking stream. Readable max width (~720 pt), bookings
/// grouped into white day cards with the daily sum in the card header.
struct BookingStreamView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.demoActive {
                        DemoBanner()
                    }
                    if !model.demoActive && model.allAccounts.isEmpty {
                        EmptyVaultCard()
                    } else {
                        StreamHeaderCard()
                    }
                    if model.scope == .investments {
                        InvestmentDashboardView()
                    }
                    if model.dayGroups.isEmpty && !(model.allAccounts.isEmpty && !model.demoActive) {
                        ContentUnavailableView(
                            model.searchText.isEmpty ? "Keine Buchungen" : "Keine Treffer",
                            systemImage: model.searchText.isEmpty ? "tray" : "magnifyingglass",
                            description: Text(model.searchText.isEmpty ? "Konto abrufen oder anderen Zeitraum wählen." : "Nichts passt zu „\(model.searchText)“.")
                        )
                        .padding(.top, 40)
                    }
                    ForEach(model.dayGroups) { day in
                        DayCard(day: day)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.canvas)
            // Drop a receipt anywhere on the stream: matched by amount/date/merchant.
            .dropDestination(for: URL.self) { urls, _ in
                model.dropAnywhere(urls)
                return !urls.isEmpty
            }
            .onChange(of: model.selectedBookingID) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = model.options.screenshotPath == nil }
        .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
        .onKeyPress(.space) {
            guard model.options.screenshotPath == nil, let b = model.selectedBooking, let d = model.documents(for: b).first else { return .ignored }
            if model.quickLookURL != nil { model.quickLookURL = nil } else { model.quickLook(d) }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "cCrR")) { press in
            guard model.options.screenshotPath == nil, let b = model.selectedBooking else { return .ignored }
            if press.characters.lowercased() == "c" {
                model.showCategorizer = true
            } else {
                model.openRuleEditor(from: b)
            }
            return .handled
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Händler, Zweck, IBAN, Betrag")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Ansicht", selection: $model.scope) {
                    ForEach(BookingScope.ordered, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 430)
                .help("⌘1 / ⌘2 / ⌘3")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.requestSyncAll() } label: { Label("Abrufen", systemImage: "arrow.triangle.2.circlepath") }
                    .help("Alle Konten abrufen (⇧⌘R)")
                Button { model.showCommandPalette = true } label: { Label("Befehle", systemImage: "command") }
                    .help("Befehlspalette (⌘K)")
                Button { model.openRuleEditor() } label: { Label("Regeln", systemImage: "wand.and.stars") }
                    .help("Kategorisierungsregeln")
                #if os(iOS)
                Button { model.showSettings = true } label: { Label("Einstellungen", systemImage: "gearshape") }
                #else
                SettingsLink { Label("Einstellungen", systemImage: "gearshape") }
                #endif
            }
        }
        .navigationTitle("")
    }
}

struct DayCard: View {
    @Environment(AppModel.self) private var model
    let day: DayGroup

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(DateText.dayHeader(day.date))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(Money.signed(day.sum))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(day.sum > 0 ? Theme.inflow : Theme.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Rectangle().fill(Theme.border).frame(height: 1)
            ForEach(Array(day.bookings.enumerated()), id: \.element.id) { i, b in
                BookingRow(booking: b, selected: model.selectedBookingID == b.id)
                    .id(b.id)
                    .dropDestination(for: URL.self) { urls, _ in
                        model.selectedBookingID = b.id
                        model.attach(urls, to: b)
                        return !urls.isEmpty
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectedBookingID = b.id }
                    .contextMenu { rowMenu(b) }
                if i < day.bookings.count - 1 {
                    Rectangle().fill(Theme.border.opacity(0.7)).frame(height: 1).padding(.leading, 64)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func rowMenu(_ b: Booking) -> some View {
        Button("Kategorisieren …", systemImage: "tag") { model.selectedBookingID = b.id; model.showCategorizer = true }
        Button("Regel für diesen Händler erstellen …", systemImage: "wand.and.stars") { model.openRuleEditor(from: b) }
        Button(b.checked ? "Als neu markieren" : "Als geprüft markieren", systemImage: "checkmark.circle") { model.setChecked(!b.checked, for: b) }
    }
}

/// Exactly three elements: signet · name + subtitle · amount.
struct BookingRow: View {
    let booking: Booking
    var selected = false

    var body: some View {
        HStack(spacing: 12) {
            MerchantSignet(merchant: booking.merchant, categorySymbol: booking.categorySymbol, showNewDot: !booking.checked)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(booking.merchant.name.isEmpty ? booking.bookingText : booking.merchant.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if booking.documentCount > 0 {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.accent.opacity(0.8))
                            .help("\(booking.documentCount) Beleg(e) – Leertaste für QuickLook")
                    }
                }
                Text(booking.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            AmountLabel(cents: booking.amountCents)
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(selected ? Theme.selection : Color.clear)
    }
}

/// Outflows dark slate, inflows an emerald badge.
struct AmountLabel: View {
    let cents: Int64
    var size: CGFloat = 14

    var body: some View {
        if cents > 0 {
            Text(Money.signed(cents))
                .font(.system(size: size, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.inflow)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Theme.inflowBadge))
        } else {
            Text(Money.format(cents))
                .font(.system(size: size, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.outflow)
        }
    }
}
