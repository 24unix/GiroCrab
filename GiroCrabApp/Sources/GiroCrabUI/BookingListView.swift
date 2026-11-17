import SwiftUI
import GiroCrabCore

/// Column 2: calm booking stream. Fills the space between sidebar and
/// inspector, bookings grouped into white day cards
/// with the daily sum in the card header.
struct BookingStreamView: View {
    @AppStorage(BookingDensity.defaultsKey) private var density: BookingDensity = .standard
    @Environment(\.textScale) private var textScale
    /// The empty state repeats the search text, which is drawn as a parameter
    /// `Text` and cannot carry `.sensitive()`.
    @Environment(\.reportRedaction) private var redaction

    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @AppStorage("showAccountAnalytics") private var showAnalytics: Bool = false
    /// View › "Auswertungen anzeigen" (GitHub #233): hides the charts and analysis cards.
    @AppStorage(ViewLayout.statisticsKey) private var showStatistics: Bool = true
    @AppStorage(ViewLayout.budgetsKey) private var showBudgets: Bool = true
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var showCashflowIOS = false
    #endif

    var body: some View {
        @Bindable var model = model
        let isOverview: Bool = { if case .allAccounts? = model.sidebarSelection { return true }; return false }()
        // „Neue Umsätze“: account cards instead of day cards, no charts
        let isNewBookings = model.sidebarSelection == .newBookings
        let cards = ViewLayout.cards(statistics: showStatistics, budgets: showBudgets)
        let emptyVault = !model.demoActive && model.allAccounts.isEmpty
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // Security lock: first, above everything else (stays visible).
                BankingPolicyBanner()
                AnnouncementBanner()
                if let focus = model.merchantFocus {
                    MerchantFocusBar(focus: focus)
                }
                #if !os(iOS)
                header(isOverview: isOverview, emptyVault: emptyVault, scope: $model.scope)
                #endif
                ScrollView {
                    // Spacing 0: the stream below is one flat run of day headers and
                    // rows that form the day cards; everything above it is one block.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        #if !os(iOS)
                        // The scroll-to-top target is the very first thing in the scroll
                        // content and carries the gap above the first card itself. As a
                        // zero-height view below a top padding, `scrollTo(…, anchor: .top)`
                        // scrolled that padding away: after a scope or period change the
                        // cards sat a few points higher than after launch (GitHub #423).
                        Color.clear.frame(height: Self.topGap).id(Self.topID)
                        #endif
                        VStack(alignment: .leading, spacing: ViewLayout.cardGap) {
                        #if os(iOS)
                        // iPhone: header scrolls away so bookings get the screen.
                        header(isOverview: isOverview, emptyVault: emptyVault, scope: $model.scope)
                        // Below the header: "to the top" on iPhone means the newest day.
                        Color.clear.frame(height: 0).id(Self.topID)
                        #endif
                        if emptyVault {
                            EmptyVaultCard()
                        }
                        if !emptyVault && model.scope != .investments {
                            MerchantLogoTipView()
                        }
                        if model.scope == .investments {
                            InvestmentDashboardView()
                        } else if cards.any, !isNewBookings, !model.allAccounts.isEmpty, isOverview || showAnalytics {
                            // Overview: always; single account: only when toggled on.
                            #if os(iOS)
                            if cards.cashflow {
                                DisclosureGroup("Cashflow-Analyse", isExpanded: $showCashflowIOS) {
                                    VStack(spacing: ViewLayout.cardGap) {
                                        CashflowCard()
                                        if cards.budgets { BudgetProgressCard() }
                                    }
                                    .padding(.top, 8)
                                }
                                .appFont(.subheadline, weight: .medium)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .frame(maxWidth: .infinity)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                            } else {
                                BudgetProgressCard()
                            }
                            #else
                            if cards.cashflow {
                                CashflowCard().transition(Motion.slide(.top))
                            }
                            if cards.budgets {
                                BudgetProgressCard().transition(Motion.slide(.top))
                            }
                            #endif
                        }
                        if model.isLoadingSelection {
                            ProgressView().controlSize(.small)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        } else if isNewBookings {
                            // the cards below bring their own empty state
                        } else if model.dayGroups.isEmpty && !(model.allAccounts.isEmpty && !model.demoActive) {
                            ContentUnavailableView(
                                model.searchText.isEmpty ? "Keine Buchungen" : "Keine Treffer",
                                systemImage: model.searchText.isEmpty ? "tray" : "magnifyingglass",
                                description: Text(model.searchText.isEmpty ? "Konto abrufen oder anderen Zeitraum wählen." : "Nichts passt zu „\(redaction.masking(model.searchText))“.")
                            )
                            .padding(.top, 40)
                        }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // One lazy element per header and per booking (not per day):
                        // rows are nearly equally high, so the scroll bar stays steady.
                        if isNewBookings {
                            NewBookingsCards()
                        } else {
                            ForEach(model.streamItems.filter { item in
                                if density == .compact, case .header = item { return false }
                                return true
                            }) { item in
                                switch item {
                                case .header(let day):
                                    DayHeader(day: day).padding(.top, day.id == firstDayID ? ViewLayout.cardGap : 14)
                                        .trackScrollDay(day.date).id(day.id)
                                case .row(let b, let isLast):
                                    DayCardRow(booking: b, isLast: isLast)
                                        .trackScrollDay(b.bookingDate)
                                        .id(b.id)
                                }
                            }
                        }
                        if model.hasMoreBookings {
                            LoadMoreBookingsFooter()
                                .padding(.top, 14)
                        }
                    }
                    .padding(.horizontal, 20)
                    #if os(iOS)
                    .padding(.top, 4)
                    #endif
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
                }
                .coordinateSpace(name: StreamDayTracker.space)
                .frame(minHeight: 0, maxHeight: .infinity)
                .scrollBounceBehavior(.basedOnSize)
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
            .capturableSheet(isPresented: Binding(
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
            }
            .background(SelectionScroller(proxy: proxy))
            // another account, group, period or view: back to the newest day
            .onChange(of: model.sidebarSelection) { _, _ in scrollToTop(proxy) }
            .onChange(of: model.period) { _, _ in scrollToTop(proxy) }
            .onChange(of: model.scope) { _, _ in scrollToTop(proxy) }
            .onChange(of: model.scrollToDay) { _, jump in
                guard let day = jump?.day else { return }
                let first = model.dayGroups.first(where: { $0.date == day })?.bookings.first
                withAnimation(Motion.animation(.easeOut(duration: 0.25))) {
                    if density == .compact, let first {
                        proxy.scrollTo(first.id, anchor: .top)
                    } else {
                        proxy.scrollTo(day, anchor: .top)
                    }
                }
                // select the day's first booking so the detail pane follows
                if let first {
                    // only when the selection really changes: otherwise nothing consumes the flag
                    if model.selectedBookingID != first.id { model.jumpSelectedBookingID = first.id }
                    model.selectedBookingID = first.id
                    // Fallback once the day scroll has run: the booking must be on screen, also
                    // when the day cannot reach the top edge (a short list, the lazy stack
                    // had not built the day yet). A no-op when it is visible already.
                    let token = jump?.token
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        guard model.scrollToDay?.token == token else { return }
                        withAnimation(Motion.animation(.easeOut(duration: 0.15))) {
                            proxy.scrollTo(first.id, anchor: density == .standard ? nil : .top)
                        }
                    }
                }
            }
        }
        // Pull-to-refresh (iOS): iCloud merge + bank sync of the current selection
        .refreshable { await model.refreshCurrentView() }
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
        .searchable(text: $model.searchText, placement: .toolbar, prompt: textScale > 1 ? "Händler, Zweck, IBAN …" : "Händler, Zweck, IBAN / Kontonummer, Betrag")
        #if os(iOS)
        .modifier(MainToolbar())
        #endif
        // A real window title (Window menu, Mission Control, VoiceOver); the
        // toolbar keeps its room for the scope picker.
        #if os(iOS)
        .modifier(WindowTitle(title: model.title))
        #endif
        .bookingOutputSheets()
    }


    @ViewBuilder
    private func header(isOverview: Bool, emptyVault: Bool, scope: Binding<BookingScope>) -> some View {
                VStack(alignment: .leading, spacing: ViewLayout.cardGap) {
                    // Marketing screenshots (`--screenshot`) look like a real vault: no demo banner.
                    if model.demoActive && LaunchOptions.current.screenshotPath == nil {
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
                    }
                }
                #if os(iOS)
                // the scroll content already carries the 20pt side padding
                .padding(.top, 4)
                .padding(.bottom, 6)
                #else
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, ViewLayout.cardGap)
                #endif
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

    private var firstDayID: String? {
        for case .header(let d) in model.streamItems { return d.id }
        return nil
    }

    private static let topID = "stream-top"
    #if !os(iOS)
    /// Gap between the fixed header and the first card of the scroll content.
    static let topGap: CGFloat = ViewLayout.cardGap
    #endif


    private func scrollToTop(_ proxy: ScrollViewProxy) {
        model.scrollFocusDay = nil
        proxy.scrollTo(Self.topID, anchor: .top)
    }
}


/// Print and export sheets plus the file exporters behind the menu commands; shared by the
/// booking list and the depot view, so a command works in both.
private struct BookingOutputSheets: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
        .capturableSheet(isPresented: $model.showPrintSheet) { PrintSheet() }
        .capturableSheet(isPresented: $model.showExportSheet) { ExportSheet() }
        .fileExporter(
            isPresented: $model.showCSVExporter,
            document: model.csvExport,
            contentType: .commaSeparatedText,
            defaultFilename: "GiroCrab-Buchungen"
        ) { result in
            if case .failure(let e) = result { model.showError(String(localized: "Export fehlgeschlagen"), e.localizedDescription) }
        }
        .fileExporter(
            isPresented: $model.showExportExporter,
            document: model.exportFile,
            contentType: model.exportContentType,
            defaultFilename: model.exportFilename
        ) { result in
            if case .failure(let e) = result { model.showError(String(localized: "Export fehlgeschlagen"), e.localizedDescription) }
        }
    }
}

extension View {
    func bookingOutputSheets() -> some View { modifier(BookingOutputSheets()) }
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

/// One horizontal slice of a white day card. The stream draws a card from
/// stacked slices (header, rows) so each slice can be a lazy element of its own:
/// rounded corners only at the card's top and bottom, the border only on the
/// sides in between.
/// Shown above a merchant-centred list (#495): names the merchant and leads back
/// to the view the list was opened from.
struct MerchantFocusBar: View {
    @Environment(AppModel.self) private var model
    let focus: MerchantFocus

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "storefront").foregroundStyle(Theme.secondary)
            Text("Alle Buchungen von").foregroundStyle(Theme.secondary)
            Text(focus.name).fontWeight(.semibold).lineLimit(1).sensitive(.personal)
            Text(verbatim: "· \(model.periodTitle)").foregroundStyle(Theme.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Button("Zurück", systemImage: "xmark.circle.fill") { model.leaveMerchantFocus() }
                .buttonStyle(.borderless)
                .fixedSize()
                .help("Händler-Filter aufheben und zur vorherigen Ansicht zurückkehren")
        }
        .appFont(.callout)
        .padding(.horizontal, 20).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct DayCardSegment: ViewModifier {
    @AppStorage(BookingDensity.defaultsKey) private var density: BookingDensity = .standard
    let isTop: Bool
    let isBottom: Bool

    func body(content: Content) -> some View {
        let r: CGFloat = 12
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: isTop ? r : 0, bottomLeadingRadius: isBottom ? r : 0,
            bottomTrailingRadius: isBottom ? r : 0, topTrailingRadius: isTop ? r : 0,
            style: .continuous)
        if density == .compact {
            content.frame(maxWidth: .infinity)
        } else {
            content
                .frame(maxWidth: .infinity)
                .background(shape.fill(Theme.card))
                .clipShape(shape)
                .overlay {
                    // The border of the whole card: stroke a shape that reaches 1 pt past
                    // an open edge and clip it, so only top/bottom slices draw that edge.
                    Color.clear.overlay {
                        shape.strokeBorder(Theme.border, lineWidth: 1)
                            .padding(.top, isTop ? 0 : -1)
                            .padding(.bottom, isBottom ? 0 : -1)
                    }
                    .clipped()
                    .allowsHitTesting(false)
                }
        }
    }
}

/// Date groups bookings without repeating a daily total.
struct DayHeader: View {
    @AppStorage(BookingDensity.defaultsKey) private var density: BookingDensity = .standard
    @Environment(AppModel.self) private var model
    let day: DayGroup

    var body: some View {
        // this day is the one the balance chart's marker points to (#593)
        let marked = model.streamHighlightDay == day.date
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if marked {
                    Circle().fill(Theme.accent).frame(width: 7, height: 7)
                }
                Text(DateText.dayHeader(day.date))
                    .appFont(.subheadline, weight: .semibold)
                    .foregroundStyle(marked ? Theme.accent : Theme.text)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, density == .compact ? 4 : 10)
            .background(marked ? Theme.accent.opacity(0.12) : Color.clear)
            Rectangle().fill(Theme.border).frame(height: 1)
        }
        .modifier(DayCardSegment(isTop: true, isBottom: false))
    }
}

/// Reports the day of the stream element that crosses a line just below the top edge of the
/// scroll view, so the balance chart can follow the scroll position (#593). The geometry
/// callback fires only when the Boolean flips, not on every scroll tick.
private struct StreamDayTracker: ViewModifier {
    static let space = "bookingStream"
    /// Distance from the top edge of the scroll view in points.
    private static let line: CGFloat = 24
    @Environment(AppModel.self) private var model
    @State private var crossing = false
    let day: String

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: Bool.self) { proxy in
                let f = proxy.frame(in: .named(Self.space))
                return f.minY <= Self.line && f.maxY > Self.line
            } action: { crosses in
                guard crosses != crossing else { return }
                crossing = crosses
                if crosses {
                    model.scrollCrossing[day, default: 0] += 1
                    if model.scrollFocusDay != day { model.scrollFocusDay = day }
                } else {
                    release()
                }
            }
            // the lazy stack drops rows that scrolled far away without a last callback
            .onDisappear {
                guard crossing else { return }
                crossing = false
                release()
            }
    }

    /// A day has several elements (header, rows): the focus ends only when none of them is
    /// left on the line. A short delay covers the hand-over to the next day's element.
    private func release() {
        let left = (model.scrollCrossing[day] ?? 1) - 1
        model.scrollCrossing[day] = left > 0 ? left : nil
        guard left <= 0, model.scrollFocusDay == day else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            if model.scrollCrossing[day] == nil, model.scrollFocusDay == day { model.scrollFocusDay = nil }
        }
    }
}

private extension View {
    /// Must come before `.id(...)`: after it, the geometry modifier takes the scroll target away
    /// from `ScrollViewProxy.scrollTo` and every jump to a day or booking does nothing.
    func trackScrollDay(_ day: String) -> some View { modifier(StreamDayTracker(day: day)) }
}

/// One booking of a day card; the last one closes the card.
struct DayCardRow: View {
    @Environment(\.textScale) private var textScale
    @AppStorage(BookingDensity.defaultsKey) private var density: BookingDensity = .standard
    @Environment(AppModel.self) private var model
    let booking: Booking
    let isLast: Bool
    @State private var compactDetailsCollapsed = false

    var body: some View {
        let b = booking
        VStack(spacing: 0) {
                BookingRow(booking: b, compactDetailsCollapsed: compactDetailsCollapsed)
                    .dropDestination(for: URL.self) { urls, _ in
                        guard model.attach(urls, to: b) else { return false }
                        model.selectedBookingID = b.id
                        return true
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        #if os(macOS)
                        // Finder-style: ⌘-click adds/removes, ⇧-click selects a range.
                        let flags = ClickModifiers.atLastMouseDown
                        if density == .compact, model.selectedBookingID == b.id,
                           !flags.contains(.command), !flags.contains(.shift) {
                            compactDetailsCollapsed.toggle()
                        } else {
                            compactDetailsCollapsed = false
                        }
                        model.selectBooking(b.id, toggle: flags.contains(.command), extend: flags.contains(.shift))
                        #else
                        if density == .compact, model.selectedBookingID == b.id {
                            compactDetailsCollapsed.toggle()
                        } else {
                            compactDetailsCollapsed = false
                        }
                        model.selectBooking(b.id)
                        #endif
                        model.showBookingSheet = true
                    }
                    .modifier(RowSelectionTraits(id: b.id))
                    // simultaneous, so single clicks keep selecting without the double-click delay
                    .simultaneousGesture(TapGesture(count: 2).onEnded { model.editNote(for: b) })
                    .contextMenu { rowMenu(b) }
                    #if os(macOS)
                    // onto a sidebar category (#366); the payload is read when the drag starts
                    .draggable(BookingDrag.payload(model.categorizeTargets(for: b).map(\.id)))
                    #endif
            if !isLast || density == .compact {
                Rectangle().fill(Theme.border.opacity(0.7)).frame(height: 1)
                    .padding(.leading, density == .compact ? 14 : 64)
            }
        }
        .modifier(DayCardSegment(isTop: false, isBottom: isLast))
        .onChange(of: model.selectedBookingID) { _, id in
            if id != booking.id { compactDetailsCollapsed = false }
        }
    }

    @ViewBuilder
    private func rowMenu(_ b: Booking) -> some View {
        CategoryAssignMenu(booking: b)
        Button("Regel für diesen Händler erstellen …", systemImage: "wand.and.stars") { model.openRuleEditor(from: b) }
        Button("Notiz bearbeiten …", systemImage: "note.text") { model.editNote(for: b) }
        TagsMenu(model: model, booking: b)
        Button("Umsatz aufteilen (Splitbuchung) …", systemImage: "arrow.triangle.branch") { model.splitBooking = b }
        LoanAssignMenu(model: model, booking: b, hidesWhenUnavailable: true)
        Divider()
        Button("Nach „\(b.counterparty.isEmpty ? b.merchantName : b.counterparty)“ suchen", systemImage: "magnifyingglass") {
            model.searchText = b.counterparty.isEmpty ? b.merchantName : b.counterparty
        }
        .disabled(b.counterparty.isEmpty && b.merchantName.isEmpty)
        Button("Neue Überweisung aus Buchung …", systemImage: "paperplane") { model.openTransfer(from: b) }
            .disabled(!model.canTransfer)
        Button("Als Dauerauftrag anlegen …", systemImage: "repeat") { model.newStandingOrder(from: b) }
            .disabled(!model.canMakeStandingOrder(from: b))
        Button("Umsatz kopieren", systemImage: "doc.on.doc") { copyToPasteboard(b.clipboardLine) }
        exportMenuButton(for: b)
        Divider()
        Button(b.checked ? "Als neu markieren" : "Als geprüft markieren", systemImage: "checkmark.circle") { model.setChecked(!b.checked, for: b) }
    }

    @ViewBuilder
    private func exportMenuButton(for b: Booking) -> some View {
        let count = model.isMultiSelection && model.selectedBookingIDs.contains(b.id)
            ? model.selectedBookingIDs.count : 1
        Button(count > 1
               ? String(localized: "\(count) Umsätze exportieren …")
               : String(localized: "Umsatz exportieren …"),
               systemImage: "square.and.arrow.up") {
            if !model.selectedBookingIDs.contains(b.id) { model.selectedBookingID = b.id }
            model.openBookingExport(selection: true)
        }
    }
}

/// The purpose shown behind the name in a booking row (#497).
enum ListPurpose {
    static func text(for b: Booking) -> String? {
        text(purpose: b.purpose, cleanPurpose: b.cleanPurpose,
             shownName: b.merchant.name.isEmpty ? b.bookingText : b.merchant.name,
             counterparty: b.counterparty, paymentMethod: b.paymentMethod, bookingText: b.bookingText)
    }

    /// One line of purpose, or nil when there is none or it only repeats what the
    /// row already shows (merchant name, counterparty, payment method), as card
    /// payments often do.
    static func text(purpose: String, cleanPurpose: String, shownName: String, counterparty: String,
                     paymentMethod: String, bookingText: String) -> String? {
        let raw = cleanPurpose.isEmpty ? purpose : cleanPurpose
        let line = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let key = normalized(line)
        guard !key.isEmpty else { return nil }
        for shown in [shownName, counterparty, paymentMethod, bookingText] {
            let other = normalized(shown)
            if !other.isEmpty, other.contains(key) { return nil }
        }
        return line
    }

    /// Letters and digits only, case-insensitive: "REWE Markt GmbH" ≙ "rewe-markt gmbh".
    private static func normalized(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }
}

/// Exactly three elements: signet · name + subtitle · amount.
struct BookingRow: View {
    @Environment(\.reportRedaction) private var redaction
    @AppStorage(BookingDensity.defaultsKey) private var density: BookingDensity = .standard
    @Environment(\.textScale) private var textScale
    @Environment(AppModel.self) private var model
    let booking: Booking
    var compactDetailsCollapsed = false
    /// Amazon orders: drill-down of all items (and the refunded order's items)
    /// below the row; collapsed rows keep the uniform list height.
    @State private var amazonExpanded = false
    @AppStorage(ViewLayout.hiddenCategoryChipAccountsKey) private var hiddenCategoryChipAccountsRaw = ""

    private var showsCategoryChip: Bool {
        !hiddenCategoryChipAccountsRaw.split(separator: ",").compactMap { Int64($0) }.contains(booking.accountId)
    }

    private var showsDetails: Bool {
        density.showsDetails(isActive: density == .compact && model.selectedBookingID == booking.id && !compactDetailsCollapsed)
    }

    private var effectiveDensity: BookingDensity { showsDetails ? .spacious : density }
    private var detailInset: CGFloat { 36 * textScale + 12 + (density == .compact ? 80 * textScale + 4 : 0) }
    private var isSingleLine: Bool { density == .compact && !showsDetails }

    private var visiblePurpose: String {
        showsDetails ? BookingInlineDetails.fullPurpose(for: booking) : density.purpose(for: booking)
    }

    private var amazonRef: AmazonOrderRef? {
        AmazonOrderRef.parse(purpose: booking.purpose, merchantDomain: booking.merchantDomain,
                             bookingText: booking.bookingText)
    }

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compactChip: Bool { sizeClass == .compact }
    #else
    private var compactChip: Bool { density == .compact }
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: isSingleLine ? .center : .top, spacing: density == .compact ? 8 : 12) {
            if density == .compact {
                Text(DateText.medium(booking.bookingDate))
                    .appFont(.callout, monospacedDigit: true)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: 80 * textScale, alignment: .leading)
            }
            MerchantSignet(merchant: booking.merchant, categorySymbol: booking.categorySymbol, size: isSingleLine ? 26 : 36, showNewDot: !booking.checked)
                .opacity(booking.isPending ? 0.7 : 1)
                .overlay {
                    // not booked yet: dashed outline instead of a solid tile
                    if booking.isPending {
                        RoundedRectangle(cornerRadius: (isSingleLine ? 26 : 36) * 0.28, style: .continuous)
                            .strokeBorder(Theme.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(booking.merchant.name.isEmpty ? booking.bookingText : booking.merchant.name)
                        .sensitive()
                        .appFont(.body, weight: .semibold)
                        .foregroundStyle(Theme.text)
                        .lineLimit(showsDetails ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    if booking.documentCount > 0 {
                        Image(systemName: "doc.text.fill")
                            .appFont(.caption)
                            .foregroundStyle(Theme.accent.opacity(0.8))
                            .help("\(booking.documentCount) Beleg(e) – Leertaste für Vorschau")
                    }
                    if model.recurringSeries(for: booking) != nil {
                        Image(systemName: "repeat")
                            .appFont(.caption, weight: .semibold)
                            .foregroundStyle(Theme.secondary)
                            .help("Wiederkehrende Buchung")
                            .accessibilityLabel("Wiederkehrend")
                    }
                    if isSingleLine && showsCategoryChip {
                        // Keep the name and amount first. Show the category only
                        // when its complete label fits; the purpose yields first.
                        ViewThatFits(in: .horizontal) {
                            BookingCategoryLabel(booking: booking).fixedSize()
                            Color.clear.frame(width: 0, height: 0)
                        }
                        .layoutPriority(-1)
                    }
                    if isSingleLine, !booking.tags.isEmpty {
                        // like the category: only when the markers fit, the purpose yields first
                        ViewThatFits(in: .horizontal) {
                            BookingTagMarkers(tags: booking.tags)
                            Color.clear.frame(width: 0, height: 0)
                        }
                        .layoutPriority(-1)
                    }
                    if isSingleLine, !visiblePurpose.isEmpty {
                        Text(visiblePurpose)
                            .sensitive()
                            .appFont(.callout)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                            .layoutPriority(-2)
                    }
                }
                if !showsDetails && !isSingleLine {
                    HStack(spacing: 6) {
                        #if !os(iOS)
                        if model.showsAccountMarkers {
                            ViewThatFits(in: .horizontal) {
                                AccountChip(label: model.accountShortLabel(booking.accountId), color: model.accountColor(booking.accountId),
                                            symbol: model.accountSymbol(booking.accountId), compact: compactChip)
                                AccountChip(label: model.accountShortLabel(booking.accountId), color: model.accountColor(booking.accountId),
                                            symbol: model.accountSymbol(booking.accountId), compact: true)
                            }
                        }
                        #endif
                        // category with the sidebar's icon and colour, then the payment method
                        if showsCategoryChip {
                            BookingCategoryLabel(booking: booking)
                                .layoutPriority(1)
                        }
                        BookingTagMarkers(tags: booking.tags)
                        if let ref = amazonRef {
                            // Amazon order: what was ordered beats the "Bestellung" kind label.
                            // Refunds show the refunded order's items (joined via the order code).
                            let refundSource = ref.isRefund ? model.amazonRefundSource(booking) : nil
                            // Refund rows start flush like every other row ("· item…");
                            // the ↩ marker goes at the end of the item text.
                            let itemsText = refundSource.map { "· \($0.items)  ↩" }
                                ?? (ref.items.isEmpty ? nil : "· \(ref.items)")
                            if let itemsText {
                                Text(itemsText)
                                    .sensitive()
                                    .appFont(.callout)
                                    .foregroundStyle(Theme.secondary)
                                    .lineLimit(1)
                                    .layoutPriority(-1)
                                    .help(ref.isRefund
                                          ? "Erstattung für Bestellung #\(ref.code)"
                                          : ref.itemList.joined(separator: "\n"))
                            }
                            if ref.moreCount > 0 {
                                // items beyond the two shown; the drill-down lists everything
                                Text("+\(ref.moreCount) weitere")
                                    .appFont(.caption2, weight: .medium)
                                    .foregroundStyle(Theme.tertiary)
                                    .lineLimit(1)
                                    .help(ref.itemList.dropFirst(2).joined(separator: "\n"))
                            }
                            if ref.isSubscription {
                                // "D01-…" charges are the recurring Spar-Abo, plain orders are one-off
                                Label("Abo", systemImage: "arrow.triangle.2.circlepath")
                                    .labelStyle(.titleAndIcon)
                                    .appFont(.caption2, weight: .medium)
                                    .foregroundStyle(Theme.tertiary)
                                    .help("Abonnement (Spar-Abo) – wiederkehrende Abbuchung")
                            }
                            Text("· #\(ref.code)")
                                .sensitive()
                                .appFont(.callout, monospacedDigit: true)
                                .foregroundStyle(Theme.tertiary)
                                .lineLimit(1)
                                .fixedSize()
                                .layoutPriority(-1)
                            // drill-down when there is more than the head can show
                            if ref.itemList.count > 1 || refundSource != nil {
                                Button { amazonExpanded.toggle() } label: {
                                    Image(systemName: amazonExpanded ? "chevron.down" : "chevron.right")
                                        .appFont(.caption2, weight: .semibold)
                                        .foregroundStyle(Theme.tertiary)
                                }
                                .buttonStyle(.borderless)
                                .help(amazonExpanded ? "Artikel einklappen" : "Alle Artikel anzeigen")
                                .accessibilityLabel(amazonExpanded ? Text("Artikel einklappen") : Text("Alle Artikel anzeigen"))
                            }
                        } else if density == .compact, !density.purpose(for: booking).isEmpty {
                            Text(density.purpose(for: booking))
                                .sensitive()
                                .appFont(.callout)
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1)
                                .layoutPriority(-1)
                        } else if let counter = model.counterAccount(for: booking) {
                            Text("· ⇄ \(counter.name)")
                                .sensitive()
                                .appFont(.callout)
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1)
                                .layoutPriority(-1)
                        } else if !booking.paymentMethod.isEmpty {
                            Text("· \(booking.paymentMethod)")
                                .appFont(.callout)
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1)
                                .layoutPriority(-1)
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .clipped()
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(0)
            Spacer(minLength: isSingleLine ? 0 : 8)
            // the row just checked in a list of new bookings stays without a mark until it leaves
            if booking.checked, model.lingeringBookingID != booking.id {
                Image(systemName: "checkmark")
                    .appFont(.caption, weight: .semibold)
                    .foregroundStyle(Theme.tertiary)
                    .help("Geprüft")
            }
            if booking.isPending {
                Image(systemName: "clock")
                    .appFont(.caption, weight: .semibold)
                    .foregroundStyle(Theme.tertiary)
                    .help("Vorgemerkt – noch nicht gebucht")
                    .accessibilityLabel("Vorgemerkt")
            }
            if let ref = amazonRef {
                // Order account: the direction is never colour alone — charges get a
                // minus, refunds a plus (and a spoken label); both are badged
                // symmetrically (same padding, same alignment).
                Text(ref.isRefund ? Money.signed(booking.amountCents) : Money.format(-abs(booking.amountCents)))
                    .sensitive(.amounts)
                    .appFont(.body, weight: .semibold, monospacedDigit: true)
                    .foregroundStyle(ref.isRefund ? Theme.inflow : Theme.charge)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(ref.isRefund ? Theme.inflowBadge : Theme.outflowBadge))
                    .lineLimit(1).fixedSize()
                    .help(ref.isRefund ? "Gutschrift (Erstattung)" : "Bestellung")
                    .accessibilityLabel(Text(verbatim: "\(ref.isRefund ? String(localized: "Erstattung") : String(localized: "Belastung")): \(redaction.masking(Money.format(abs(booking.amountCents)), .amounts))"))
            } else {
                AmountLabel(cents: booking.amountCents)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, booking.isPending ? 6 : 0)
                    .padding(.vertical, booking.isPending ? 2 : 0)
                    .overlay {
                        if booking.isPending {
                            Capsule().strokeBorder(Theme.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        }
                    }
            }
        }
        if (showsDetails || density == .standard), amazonRef == nil, !visiblePurpose.isEmpty {
            Text(visiblePurpose)
                .sensitive()
                .appFont(.callout)
                .foregroundStyle(Theme.secondary)
                .lineLimit(showsDetails ? nil : 1)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, detailInset)
        }
        if showsDetails {
            BookingInlineDetails(booking: booking)
                .padding(.top, 4)
                .padding(.leading, detailInset)
        }
        if (amazonExpanded && density != .compact) || showsDetails, let ref = amazonRef {
            // drill-down: every item on its own line, indented under the signet
            VStack(alignment: .leading, spacing: 2) {
                if let source = model.amazonRefundSource(booking) {
                    Text("Erstattung zu:").appFont(.caption2).foregroundStyle(Theme.tertiary)
                    ForEach(source.list, id: \.self) { item in
                        Text(item).sensitive().appFont(.callout).foregroundStyle(Theme.secondary)
                            .textSelection(.enabled)
                    }
                } else {
                    ForEach(ref.itemList, id: \.self) { item in
                        Text(item).sensitive().appFont(.callout).foregroundStyle(Theme.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.leading, detailInset)
            .padding(.bottom, 4)
        }
        }
        #if os(macOS)
        .frame(minHeight: (effectiveDensity == .compact ? 28 : 44) * textScale, alignment: .top)
        #else
        .frame(minHeight: 44, alignment: .top)
        #endif
        .padding(.horizontal, 14)
        .padding(.vertical, effectiveDensity.verticalPadding * textScale)
        .background {
            ZStack {
                // not booked yet: light diagonal hatching under the whole row
                if booking.isPending { PendingHatch() }
                RowSelectionBackground(id: booking.id)
            }
        }
    }
}

/// Light diagonal hatching that marks a not yet booked ("vorgemerkt") row.
/// Drawn with the theme's secondary colour, so it reads in light and dark.
struct PendingHatch: View {
    var spacing: CGFloat = 7
    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += spacing
            }
            ctx.stroke(path, with: .color(Theme.secondary.opacity(0.14)), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Selection highlight reads selection locally instead of invalidating day cards.
/// Compact booking rows also observe the active selection to expand their details.
private struct RowSelectionBackground: View {
    @Environment(AppModel.self) private var model
    let id: Booking.ID

    var body: some View {
        model.selectedBookingIDs.contains(id) ? Theme.selection : Color.clear
    }
}

/// "Selected" for assistive technologies; like `RowSelectionBackground`, it keeps
/// the selection out of the day card's dependencies.
private struct RowSelectionTraits: ViewModifier {
    @Environment(AppModel.self) private var model
    let id: Booking.ID

    func body(content: Content) -> some View {
        content.accessibilityAddTraits(model.selectedBookingIDs.contains(id) ? [.isButton, .isSelected] : .isButton)
    }
}

/// Scrolls the stream to the selected booking. A view of its own, so the
/// selection is not a dependency of the whole list.
private struct SelectionScroller: View {
    @AppStorage(BookingDensity.defaultsKey) private var density: BookingDensity = .standard
    @Environment(AppModel.self) private var model
    let proxy: ScrollViewProxy

    var body: some View {
        Color.clear
            .onChange(of: model.selectedBookingID) { _, id in
                guard let id else { return }
                // the chart marker follows the selected booking (#593)
                if let day = model.selectedBooking?.bookingDate, model.selectedBookingID == id, model.scrollFocusDay != day {
                    model.scrollFocusDay = day
                }
                // the day jump already scrolled to the day: do not override it
                if model.jumpSelectedBookingID == id { model.jumpSelectedBookingID = nil; return }
                // Every row is an element of the lazy stream, so the proxy finds it
                // even while it is off-screen.
                withAnimation(Motion.animation(.easeOut(duration: 0.15))) {
                    // Expanded rows can exceed the viewport: keep their title visible.
                    proxy.scrollTo(id, anchor: density == .standard ? nil : .top)
                }
            }
    }
}

/// Category of a booking as in the sidebar: its icon and colour
/// ("Ohne Kategorie" like the sidebar entry, in the warning colour).
struct BookingCategoryLabel: View {
    let booking: Booking
    @Environment(AppModel.self) private var model

    var body: some View {
        let none = booking.categoryName.isEmpty
        let color = none ? Theme.warning : Color.readable(hex: booking.categoryColorHex)
        HStack(spacing: 3) {
            Image(systemName: none ? "questionmark.folder" : (booking.categorySymbol.isEmpty ? "tag.fill" : booking.categorySymbol))
                .appFont(.caption)
            Text(none ? model.uncategorizedLabel : booking.categoryName)
                .sensitive(.labels)
                .appFont(.callout, weight: .medium)
                .lineLimit(1)
        }
        .foregroundStyle(color)
    }
}

/// Account of a booking in mixed lists: the account's symbol in its colour
/// + short name (#170 – a symbol is easier to spot than a small dot).
struct AccountChip: View {
    let label: String
    let color: Color
    var symbol = "building.columns"
    /// Narrow rows: just the symbol (the category keeps the room).
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .appFont(.caption, weight: .semibold)
                .foregroundStyle(color)
            if !compact {
                Text(label)
                    .sensitive()
                    .appFont(.subheadline, weight: .medium)
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

/// Outflows dark slate (or red / orange, Einstellungen › Allgemein, #218), inflows an
/// emerald (or blue) badge; the sign always carries the direction too.
struct AmountLabel: View {
    let cents: Int64
    @AppStorage(NegativeAmountStyle.defaultsKey) private var negativeStyle: NegativeAmountStyle = .neutral

    var body: some View {
        if cents > 0 {
            Text(Money.signed(cents))
                .sensitive(.amounts)
                .appFont(.body, weight: .semibold, monospacedDigit: true)
                .foregroundStyle(negativeStyle.positiveColor)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(negativeStyle.positiveBadge))
        } else {
            Text(Money.format(cents))
                .sensitive(.amounts)
                .appFont(.body, weight: .medium, monospacedDigit: true)
                .foregroundStyle(cents < 0 ? negativeStyle.color : Theme.outflow)
        }
    }
}

/// End of the list: the default limit cut off older bookings – offer to load them.
struct LoadMoreBookingsFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            Text("\(model.bookings.count) von \(model.bookings.count + model.remainingBookingCount) Buchungen geladen – ältere Buchungen sind noch nicht sichtbar.")
                .appFont(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            // always laid out, only faded: the footer keeps its height while a page loads
            ProgressView().controlSize(.small)
                .opacity(model.isLoadingMoreBookings ? 1 : 0)
                .accessibilityHidden(!model.isLoadingMoreBookings)
            HStack(spacing: 10) {
                Button("Weitere Buchungen laden") { model.loadMoreBookings() }
                    .disabled(model.isLoadingMoreBookings)
                Button("Alle Buchungen laden") { model.loadAllBookings() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        // The footer scrolled into view: fetch the next page. Runs again after
        // each page for as long as the footer stays visible.
        .task(id: model.bookings.count) { model.loadMoreBookings() }
    }
}

/// macOS: the window carries the view's title, the toolbar does not show it
/// (macOS 15+). iOS keeps the empty navigation title as before.
struct WindowTitle: ViewModifier {
    let title: String
    /// The title bar is drawn by AppKit, so `.sensitive()` cannot cover it:
    /// any bug report capture shows the app name (the title may be an account).
    @Environment(\.reportRedaction) private var redaction

    func body(content: Content) -> some View {
        #if os(macOS)
        let title = redaction.isDisjoint(with: [.personal, .labels]) ? title : "GiroCrab"
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
    @AppStorage(ViewLayout.inspectorKey) private var showInspector = true
    @AppStorage(PrivacyMode.enabledKey) private var privacyMode = false

    func body(content: Content) -> some View {
        #if os(iOS)
        content.toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.requestSyncAll() } label: { Label("Abrufen", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(model.bankingBlocksAll)
                Menu {
                    Button { model.openTransfer() } label: { Label("Überweisen", systemImage: "paperplane") }
                        .disabled(!model.canTransfer)
                    Button { model.openBookingExport() } label: { Label("Umsätze exportieren …", systemImage: "square.and.arrow.up") }
                    Button { model.showPrintSheet = true } label: { Label("Drucken …", systemImage: "printer") }
                    Button { model.openRuleEditor() } label: { Label("Regeln", systemImage: "wand.and.stars") }
                    Toggle(isOn: $privacyMode) { Label("Privatmodus", systemImage: "eye.slash") }
                    Button { model.showSettings = true } label: { Label("Einstellungen", systemImage: "gearshape") }
                    if model.hasOwnVault {
                        Button { model.lock() } label: { Label("Tresor sperren", systemImage: "lock") }
                    }
                    if model.demoActive && (model.hasOwnVault || AppModel.vaultMayHoldRealData) {
                        Button { model.showOwnVault() } label: { Label(AppModel.vaultMayHoldRealData ? "Zurück zum eigenen Tresor" : "Eigenes Konto anlegen", systemImage: "lock.open") }
                    } else if !model.demoActive {
                        Button { model.showDemo() } label: { Label("Demo-Daten-Vorschau starten", systemImage: "theatermasks") }
                    }
                } label: { Label("Mehr", systemImage: "ellipsis.circle") }
            }
        }
        #else
        content.toolbar(id: "girocrab.main") {
            ToolbarItem(id: "scope", placement: .principal) {
                // Keep one customizable toolbar item, with the filter for the current view.
                if model.sidebarSelection == .wealth {
                    WealthScopePicker()
                } else if model.sidebarSelection == .documents {
                    DocumentsScopePicker()
                } else {
                    switch model.presentation {
                    case .securities: DepotTabPicker()
                    // Sachwerte have neither booking scopes nor depot tabs; the item stays so the
                    // customizable toolbar keeps its layout
                    case .tangible: Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                    case .bookings: BookingScopePicker().disabled(model.sidebarSelection == .newBookings)
                    }
                }
            }
            .defaultCustomization(.visible, options: .alwaysAvailable) // pinned: not draggable/removable, so the others keep their slots (#609)
            ToolbarItem(id: "transfer", placement: .primaryAction) {
                Button { model.openTransfer() } label: { Label("Überweisen", systemImage: "paperplane") }
                    .help("Neue Überweisung (⌘N)")
                    .disabled(!model.canTransfer)
            }
            ToolbarItem(id: "sync", placement: .primaryAction) {
                Button { model.requestSyncAll() } label: { Label("Abrufen", systemImage: "arrow.triangle.2.circlepath") }
                    .help(model.bankingBlocksAll ? (BankingPolicy.shared.gate?.message ?? "") : String(localized: "Alle Konten abrufen (⌘R)"))
                    .disabled(model.bankingBlocksAll)
            }
            ToolbarItem(id: "inspector", placement: .primaryAction) {
                Button { showInspector.toggle() } label: { Label("Informationen", systemImage: "sidebar.trailing") }
                    .help(showInspector ? String(localized: "Informationen ausblenden (⌥⌘I)") : String(localized: "Informationen einblenden (⌥⌘I)"))
            }
            ToolbarItem(id: "privacy", placement: .primaryAction) {
                Toggle(isOn: $privacyMode) { Label("Privatmodus", systemImage: privacyMode ? "eye.slash" : "eye") }
                    .help(privacyMode ? String(localized: "Privatmodus beenden (⇧⌘H)") : String(localized: "Privatmodus: Beträge ausblenden (⇧⌘H)"))
            }
            extraToolbarItems
        }
        #endif
    }

    #if os(macOS)
    /// Second half of the customizable toolbar: `ToolbarContentBuilder` has no `buildBlock` for more than
    /// 10 children, so the items are split in two (IDs, order and `showsByDefault` unchanged).
    @ToolbarContentBuilder
    private var extraToolbarItems: some CustomizableToolbarContent {
        ToolbarItem(id: "palette", placement: .primaryAction, showsByDefault: false) {
            Button { model.showCommandPalette = true } label: { Label("Befehle", systemImage: "command") }
                .help("Befehlspalette (⌘K)")
        }
        ToolbarItem(id: "export", placement: .primaryAction, showsByDefault: false) {
            Button { model.openBookingExport() } label: { Label("Umsätze exportieren", systemImage: "square.and.arrow.up") }
                .help("Umsätze als PDF, CSV oder CAMT.053 exportieren … (#53 / #372)")
        }
        ToolbarItem(id: "print", placement: .primaryAction, showsByDefault: false) {
            Button { model.showPrintSheet = true } label: { Label("Drucken", systemImage: "printer") }
                .help("Gefilterte Buchungen drucken … (⌘P)")
        }
        ToolbarItem(id: "rules", placement: .primaryAction, showsByDefault: false) {
            Button { model.openRuleEditor() } label: { Label("Regeln", systemImage: "wand.and.stars") }
                .help("Kategorisierungsregeln … (⌥⌘K)")
        }
        ToolbarItem(id: "lock", placement: .primaryAction, showsByDefault: false) {
            Button { model.lock() } label: { Label("Tresor sperren", systemImage: "lock") }
                .help("Tresor sperren (⌃⌘L)")
                .disabled(!model.hasOwnVault)
        }
        ToolbarItem(id: "settings", placement: .primaryAction, showsByDefault: false) {
            SettingsLink { Label("Einstellungen", systemImage: "gearshape") }
                .help("Einstellungen … (⌘,)")
        }
    }
    #endif
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
