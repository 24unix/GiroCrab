import SwiftUI
import GiroCrabCore

/// Column 2: calm booking stream. Readable max width (~720 pt), bookings
/// grouped into white day cards with the daily sum in the card header.
struct BookingStreamView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @AppStorage("showAccountAnalytics") private var showAnalytics: Bool = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var showCashflowIOS = false
    #endif

    /// Depots show positions; bookings (buys, sells) live on the clearing account.
    private var isDepot: Bool {
        if case .account(let id)? = model.sidebarSelection, let a = model.account(for: id) {
            return a.kind == .brokerage || a.name.localizedCaseInsensitiveContains("depot")
        }
        return false
    }

    var body: some View {
        @Bindable var model = model
        let isOverview: Bool = { if case .allAccounts? = model.sidebarSelection { return true }; return false }()
        let emptyVault = !model.demoActive && model.allAccounts.isEmpty
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                #if !os(iOS)
                header(isOverview: isOverview, emptyVault: emptyVault, scope: $model.scope)
                #endif
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        #if os(iOS)
                        // iPhone: header scrolls away so bookings get the screen.
                        header(isOverview: isOverview, emptyVault: emptyVault, scope: $model.scope)
                        #endif
                        Color.clear.frame(height: 0).id(Self.topID)
                        if emptyVault {
                            EmptyVaultCard()
                        }
                        if !emptyVault && model.scope != .investments {
                            MerchantLogoTipView()
                        }
                        if model.scope == .investments {
                            InvestmentDashboardView()
                        } else if !model.allAccounts.isEmpty, isOverview || showAnalytics {
                            // Overview: always; single account: only when toggled on.
                            #if os(iOS)
                            DisclosureGroup("Cashflow-Analyse", isExpanded: $showCashflowIOS) {
                                VStack(spacing: 14) {
                                    CashflowCard()
                                    BudgetProgressCard()
                                }
                                .padding(.top, 8)
                            }
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                            #else
                            CashflowCard().transition(Motion.slide(.top))
                            BudgetProgressCard().transition(Motion.slide(.top))
                            #endif
                        }
                        if model.dayGroups.isEmpty && isDepot && model.searchText.isEmpty {
                            ContentUnavailableView(
                                "Keine Buchungen im Depot",
                                systemImage: "chart.line.uptrend.xyaxis",
                                description: Text("Ein Depot zeigt seine Positionen oben. Käufe, Verkäufe und Sparpläne stehen als Buchungen im Verrechnungskonto.")
                            )
                            .frame(maxWidth: .infinity)
                            // fill the visible scroll area so the placeholder sits in its middle
                            .containerRelativeFrame(.vertical, alignment: .center)
                        } else if model.dayGroups.isEmpty && !(model.allAccounts.isEmpty && !model.demoActive) {
                            ContentUnavailableView(
                                model.searchText.isEmpty ? "Keine Buchungen" : "Keine Treffer",
                                systemImage: model.searchText.isEmpty ? "tray" : "magnifyingglass",
                                description: Text(model.searchText.isEmpty ? "Konto abrufen oder anderen Zeitraum wählen." : "Nichts passt zu „\(model.searchText)“.")
                            )
                            .padding(.top, 40)
                        }
                        ForEach(model.dayGroups) { day in
                            DayCard(day: day)
                                .id(day.id)
                        }
                        if model.hasMoreBookings {
                            LoadMoreBookingsFooter()
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 18)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
                }
                .frame(minHeight: 0, maxHeight: .infinity)
                #if os(iOS)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    // keeps the last booking clear of the floating search bar
                    Color.clear.frame(height: 64)
                }
                #endif
            }
            .background(Theme.canvas)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columnWidth = $0 }
            #if os(iOS)
            // iPhone: the detail column is not reachable by tapping, so show it as a sheet.
            .sheet(isPresented: Binding(
                get: { hSize == .compact && model.showBookingSheet && model.selectedBookingID != nil },
                set: { if !$0 { model.showBookingSheet = false } }
            )) {
                NavigationStack { InspectorView() }
                    .presentationDetents([.medium, .large])
            }
            #endif
            // Drop a receipt anywhere on the stream: matched by amount/date/merchant.
            .dropDestination(for: URL.self) { urls, _ in
                model.dropAnywhere(urls)
                return !urls.isEmpty
            }
            .onChange(of: model.selectedBookingID) { _, id in
                guard let id else { return }
                // Rows live inside lazily built day cards: an off-screen day must be
                // scrolled to first, otherwise the row's id is unknown to the proxy.
                if let day = model.dayGroups.first(where: { $0.bookings.contains { $0.id == id } }) {
                    proxy.scrollTo(day.id)
                }
                DispatchQueue.main.async {
                    withAnimation(Motion.animation(.easeOut(duration: 0.15))) { proxy.scrollTo(id) }
                }
            }
            // another account, group, period or view: back to the newest day
            .onChange(of: model.sidebarSelection) { _, _ in scrollToTop(proxy) }
            .onChange(of: model.period) { _, _ in scrollToTop(proxy) }
            .onChange(of: model.scope) { _, _ in scrollToTop(proxy) }
            .onChange(of: model.scrollToDay) { _, jump in
                guard let day = jump?.day else { return }
                withAnimation(Motion.animation(.easeOut(duration: 0.25))) { proxy.scrollTo(day, anchor: .top) }
                // select the day's first booking so the detail pane follows
                if let first = model.dayGroups.first(where: { $0.date == day })?.bookings.first {
                    model.selectedBookingID = first.id
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = model.options.screenshotPath == nil
            #if os(macOS)
            ClickModifiers.install()
            #endif
        }
        .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
        .onKeyPress(.return) {
            // The balance chart sits inside the list: with keyboard focus there,
            // Return belongs to the chart (jump to the chosen day).
            guard !model.chartHasKeyboardFocus else { return .ignored }
            guard model.options.screenshotPath == nil, let b = model.selectedBooking else { return .ignored }
            model.editNote(for: b)
            return .handled
        }
        .onChange(of: model.focusListToken) { _, _ in focused = true }
        .merchantLogoTipEligibility()
        .onKeyPress(.space) {
            guard model.options.screenshotPath == nil, let b = model.selectedBooking else { return .ignored }
            // Space is Quick Look only (as in the Finder); "Geprüft" is ⇧⌘U.
            guard let d = model.documents(for: b).first else { return .ignored }
            if model.quickLookURL != nil { model.quickLookURL = nil } else { model.quickLook(d) }
            return .handled
        }
        #if os(macOS)
        // Bearbeiten › Alles auswählen (⌘A) selects all listed bookings
        .onCommand(#selector(NSResponder.selectAll(_:))) { model.selectAllBookings() }
        // ⌘C copies the selected booking (Edit ▸ Copy)
        .onCopyCommand {
            guard let b = model.selectedBooking else { return [] }
            return [NSItemProvider(object: b.clipboardLine as NSString)]
        }
        #endif
        .onKeyPress(characters: CharacterSet(charactersIn: "cCrR")) { press in
            // leave ⌘C to the copy command above
            guard !press.modifiers.contains(.command) else { return .ignored }
            guard model.options.screenshotPath == nil, let b = model.selectedBooking else { return .ignored }
            if press.characters.lowercased() == "c" {
                model.showCategorizer = true
            } else {
                model.openRuleEditor(from: b)
            }
            return .handled
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Händler, Zweck, IBAN, Betrag")
        #if os(iOS)
        .modifier(MainToolbar())
        #endif
        // A real window title (Window menu, Mission Control, VoiceOver); the
        // toolbar keeps its room for the scope picker.
        #if os(iOS)
        .modifier(WindowTitle(title: model.title))
        #endif
        .sheet(isPresented: $model.showPrintSheet) { PrintSheet() }
        .fileExporter(
            isPresented: $model.showCSVExporter,
            document: model.csvExport,
            contentType: .commaSeparatedText,
            defaultFilename: "GiroCrab-Buchungen"
        ) { result in
            if case .failure(let e) = result { model.showError(String(localized: "Export fehlgeschlagen"), e.localizedDescription) }
        }
    }


    @ViewBuilder
    private func header(isOverview: Bool, emptyVault: Bool, scope: Binding<BookingScope>) -> some View {
                VStack(alignment: .leading, spacing: 14) {
                    if model.demoActive {
                        DemoBanner()
                    }
                    #if os(iOS)
                    Picker("Ansicht", selection: scope) {
                        ForEach(BookingScope.ordered, id: \.self) { Text($0.shortTitle).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    #endif
                    if !emptyVault {
                        StreamHeaderCard()
                        if !isOverview && !isDepot && model.scope != .investments && !model.allAccounts.isEmpty {
                            HStack {
                                Button {
                                    withAnimation(Motion.animation(.easeInOut(duration: 0.25))) { showAnalytics.toggle() }
                                } label: {
                                    Label("Analysen", systemImage: "chart.bar.xaxis")
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(showAnalytics ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .help("Cashflow und Budgets für dieses Konto ein-/ausblenden")
                                Spacer()
                            }
                        }
                    }
                }
                #if os(iOS)
                // the scroll content already carries the 20pt side padding
                .padding(.top, 4)
                .padding(.bottom, 6)
                #else
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 10)
                #endif
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(.trailing, scrollerInset)
    }

    /// macOS: width a scroller takes from the scroll area; the pinned header
    /// (outside the ScrollView) gets the same trailing inset to stay aligned.
    @State private var columnWidth: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    private var scrollerInset: CGFloat {
        #if os(macOS)
        (columnWidth > 0 && contentWidth > 0) ? max(0, columnWidth - contentWidth) : 0
        #else
        0
        #endif
    }

    private static let topID = "stream-top"


    private func scrollToTop(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.topID, anchor: .top)
    }
}

#if os(macOS)
/// Keep the toolbar control independent of list, chart and inspector updates.
/// Its only observable dependency is the selected scope. The system segmented
/// control brings arrow-key navigation, focus ring and VoiceOver with it (an
/// older selection-animation glitch no longer occurs on current macOS).
private struct BookingScopePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker("Ansicht", selection: Binding(get: { model.scope }, set: { model.scope = $0 })) {
            ForEach(BookingScope.ordered, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Ansicht wählen (⌘1, ⌘2, ⌘3)")
    }
}
#endif

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
                BookingRow(booking: b, selected: model.selectedBookingIDs.contains(b.id))
                    .id(b.id)
                    .dropDestination(for: URL.self) { urls, _ in
                        model.selectedBookingID = b.id
                        model.attach(urls, to: b)
                        return !urls.isEmpty
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        #if os(macOS)
                        // Finder-style: ⌘-click adds/removes, ⇧-click selects a range.
                        let flags = ClickModifiers.atLastMouseDown
                        model.selectBooking(b.id, toggle: flags.contains(.command), extend: flags.contains(.shift))
                        #else
                        model.selectBooking(b.id)
                        #endif
                        model.showBookingSheet = true
                    }
                    .accessibilityAddTraits(model.selectedBookingIDs.contains(b.id) ? [.isButton, .isSelected] : .isButton)
                    // simultaneous, so single clicks keep selecting without the double-click delay
                    .simultaneousGesture(TapGesture(count: 2).onEnded { model.editNote(for: b) })
                    .contextMenu { rowMenu(b) }
                if i < day.bookings.count - 1 {
                    Rectangle().fill(Theme.border.opacity(0.7)).frame(height: 1).padding(.leading, 64)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func rowMenu(_ b: Booking) -> some View {
        Button(model.isMultiSelection && model.selectedBookingIDs.contains(b.id)
               ? "\(model.selectedBookingIDs.count) Buchungen kategorisieren …" : "Kategorisieren …", systemImage: "tag") {
            if !model.selectedBookingIDs.contains(b.id) { model.selectedBookingID = b.id }
            model.showCategorizer = true
        }
        Button("Regel für diesen Händler erstellen …", systemImage: "wand.and.stars") { model.openRuleEditor(from: b) }
        Button("Notiz bearbeiten …", systemImage: "note.text") { model.editNote(for: b) }
        Button("Umsatz aufteilen (Splitbuchung) …", systemImage: "arrow.triangle.branch") { model.splitBooking = b }
        LoanAssignMenu(model: model, booking: b, hidesWhenUnavailable: true)
        Divider()
        Button("Nach „\(b.counterparty.isEmpty ? b.merchantName : b.counterparty)“ suchen", systemImage: "magnifyingglass") {
            model.searchText = b.counterparty.isEmpty ? b.merchantName : b.counterparty
        }
        .disabled(b.counterparty.isEmpty && b.merchantName.isEmpty)
        Button("Neue Überweisung aus Buchung …", systemImage: "paperplane") { model.openTransfer(from: b) }
            .disabled(!model.canTransfer)
        Button("Umsatz kopieren", systemImage: "doc.on.doc") { copyToPasteboard(b.clipboardLine) }
        Divider()
        Button(b.checked ? "Als neu markieren" : "Als geprüft markieren", systemImage: "checkmark.circle") { model.setChecked(!b.checked, for: b) }
    }
}

/// Exactly three elements: signet · name + subtitle · amount.
struct BookingRow: View {
    @Environment(AppModel.self) private var model
    let booking: Booking
    var selected = false

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compactChip: Bool { sizeClass == .compact }
    #else
    private let compactChip = false
    #endif

    var body: some View {
        HStack(spacing: 12) {
            MerchantSignet(merchant: booking.merchant, categorySymbol: booking.categorySymbol, showNewDot: !booking.checked)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(booking.merchant.name.isEmpty ? booking.bookingText : booking.merchant.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if booking.documentCount > 0 {
                        Image(systemName: "doc.text.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.accent.opacity(0.8))
                            .help("\(booking.documentCount) Beleg(e) – Leertaste für QuickLook")
                    }
                    if model.recurringSeries(for: booking) != nil {
                        Image(systemName: "repeat")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.secondary)
                            .help("Wiederkehrende Buchung")
                            .accessibilityLabel("Wiederkehrend")
                    }
                }
                HStack(spacing: 6) {
                    #if !os(iOS)
                    if model.showsAccountMarkers {
                        AccountChip(label: model.accountShortLabel(booking.accountId), color: model.accountColor(booking.accountId), compact: compactChip)
                    }
                    #endif
                    // category with the sidebar's icon and colour, then the payment method
                    BookingCategoryLabel(booking: booking)
                        .layoutPriority(1)
                    if !booking.paymentMethod.isEmpty {
                        Text("· \(booking.paymentMethod)")
                            .font(.callout)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                            .layoutPriority(-1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            }
            .layoutPriority(0)
            Spacer(minLength: 8)
            if booking.checked {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.tertiary)
                    .help("Geprüft")
            }
            AmountLabel(cents: booking.amountCents)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(selected ? Theme.selection : Color.clear)
    }
}

/// Category of a booking as in the sidebar: its icon and colour
/// ("Ohne Kategorie" like the sidebar entry, in the warning colour).
struct BookingCategoryLabel: View {
    let booking: Booking

    var body: some View {
        let none = booking.categoryName.isEmpty
        let color = none ? Theme.warning : Color.readable(hex: booking.categoryColorHex)
        HStack(spacing: 3) {
            Image(systemName: none ? "questionmark.folder" : (booking.categorySymbol.isEmpty ? "tag.fill" : booking.categorySymbol))
                .font(.caption)
            Text(none ? String(localized: "Ohne Kategorie") : booking.categoryName)
                .font(.callout.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(color)
    }
}

/// Account of a booking in mixed lists: coloured dot + short name.
struct AccountChip: View {
    let label: String
    let color: Color
    /// Narrow iPhone rows: just the dot (the category keeps the room).
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            if !compact {
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, compact ? 0 : 6)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(color.opacity(compact ? 0 : 0.12)))
        .fixedSize()
        .help(label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Konto: \(label)"))
    }
}

/// Outflows dark slate, inflows an emerald badge.
struct AmountLabel: View {
    let cents: Int64

    var body: some View {
        if cents > 0 {
            Text(Money.signed(cents))
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.inflow)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Theme.inflowBadge))
        } else {
            Text(Money.format(cents))
                .font(.body.weight(.medium).monospacedDigit())
                .foregroundStyle(Theme.outflow)
        }
    }
}

/// End of the list: the default limit cut off older bookings – offer to load them.
struct LoadMoreBookingsFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            Text("\(model.bookings.count) von \(model.bookings.count + model.remainingBookingCount) Buchungen geladen – ältere Buchungen sind noch nicht sichtbar.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("Weitere Buchungen laden (+3.000)") { model.loadMoreBookings() }
                Button("Alle Buchungen laden") { model.loadAllBookings() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

/// macOS: the window carries the view's title, the toolbar does not show it
/// (macOS 15+). iOS keeps the empty navigation title as before.
struct WindowTitle: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        #if os(macOS)
        if #available(macOS 15.0, *) {
            content.navigationTitle(title).toolbar(removing: .title)
        } else {
            content.navigationTitle(title)
        }
        #else
        content.navigationTitle("")
        #endif
    }
}

/// Toolbar of the booking list. macOS: customizable (View › Symbolleiste
/// anpassen …) – Überweisen and Abrufen are shown by default, the rest can be
/// added; every command is also in the menu bar. iOS: unchanged.
struct MainToolbar: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        #if os(iOS)
        content.toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.requestSyncAll() } label: { Label("Abrufen", systemImage: "arrow.triangle.2.circlepath") }
                Menu {
                    Button { model.openTransfer() } label: { Label("Überweisen", systemImage: "paperplane") }
                        .disabled(!model.canTransfer)
                    Button { model.exportFilteredBookingsCSV() } label: { Label("CSV exportieren …", systemImage: "square.and.arrow.up") }
                    Button { model.showPrintSheet = true } label: { Label("Drucken …", systemImage: "printer") }
                    Button { model.openRuleEditor() } label: { Label("Regeln", systemImage: "wand.and.stars") }
                    Button { model.showSettings = true } label: { Label("Einstellungen", systemImage: "gearshape") }
                    if model.demoActive && (model.hasOwnVault || AppModel.vaultMayHoldRealData) {
                        Button { model.showOwnVault() } label: { Label("Zurück zum eigenen Tresor", systemImage: "lock.open") }
                    } else if !model.demoActive {
                        Button { model.showDemo() } label: { Label("Demo-Daten-Vorschau starten", systemImage: "theatermasks") }
                    }
                } label: { Label("Mehr", systemImage: "ellipsis.circle") }
            }
        }
        #else
        content.toolbar(id: "girocrab.main") {
            ToolbarItem(id: "scope", placement: .principal) {
                BookingScopePicker()
                    .disabled(model.sidebarSelection == .documents)
            }
            ToolbarItem(id: "transfer", placement: .primaryAction) {
                Button { model.openTransfer() } label: { Label("Überweisen", systemImage: "paperplane") }
                    .help("Neue Überweisung (⌘N)")
                    .disabled(!model.canTransfer)
            }
            ToolbarItem(id: "sync", placement: .primaryAction) {
                Button { model.requestSyncAll() } label: { Label("Abrufen", systemImage: "arrow.triangle.2.circlepath") }
                    .help("Alle Konten abrufen (⌘R)")
            }
            ToolbarItem(id: "palette", placement: .primaryAction, showsByDefault: false) {
                Button { model.showCommandPalette = true } label: { Label("Befehle", systemImage: "command") }
                    .help("Befehlspalette (⌘K)")
            }
            ToolbarItem(id: "csv", placement: .primaryAction, showsByDefault: false) {
                Button { model.exportFilteredBookingsCSV() } label: { Label("CSV exportieren", systemImage: "square.and.arrow.up") }
                    .help("Gefilterte Buchungen als CSV exportieren …")
            }
            ToolbarItem(id: "print", placement: .primaryAction, showsByDefault: false) {
                Button { model.showPrintSheet = true } label: { Label("Drucken", systemImage: "printer") }
                    .help("Gefilterte Buchungen drucken … (⌘P)")
            }
            ToolbarItem(id: "rules", placement: .primaryAction, showsByDefault: false) {
                Button { model.openRuleEditor() } label: { Label("Regeln", systemImage: "wand.and.stars") }
                    .help("Kategorisierungsregeln … (⌥⌘K)")
            }
            ToolbarItem(id: "settings", placement: .primaryAction, showsByDefault: false) {
                SettingsLink { Label("Einstellungen", systemImage: "gearshape") }
                    .help("Einstellungen … (⌘,)")
            }
        }
        #endif
    }
}

#if os(macOS)
/// Modifier keys held at the last mouse-down in the app. SwiftUI runs a tap
/// gesture after the event has passed, so `NSApp.currentEvent` no longer
/// carries them; a local monitor records them as the click arrives.
@MainActor
enum ClickModifiers {
    private(set) static var atLastMouseDown: NSEvent.ModifierFlags = []
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            atLastMouseDown = event.modifierFlags.intersection([.command, .shift, .option, .control])
            return event
        }
    }
}
#endif
