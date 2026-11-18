import SwiftUI
import GiroCrabCore

/// Everything the depot view loads for one depot in one pass.
struct DepotData {
    let accountId: Int64
    /// Vault generation the data came from: data of another vault is never shown.
    let revision: Int
    let assets: [ClassifiedAsset]
    let transactions: [SecurityTransaction]
    /// The depot's value history (all of it; the period cuts it for the chart).
    let valuePoints: [DepotValuePoint]
    /// Held positions with a value history (#578) by `DepotPosition.id`, worked out once per load.
    let heldHistory: [String: ValuePosition]
    /// Positions no longer held that have a history, the latest sale first.
    let soldPositions: [ValuePosition]
    /// Savings plans recognised in the activities (nil: not loaded).
    var plans: InvestmentDashboard?
    var holdings: [Holding] { assets.map(\.holding) }

    init(accountId: Int64, revision: Int, assets: [ClassifiedAsset], transactions: [SecurityTransaction],
         valuePoints: [DepotValuePoint], valuePositions: [ValuePosition], plans: InvestmentDashboard? = nil) {
        self.plans = plans
        self.accountId = accountId
        self.revision = revision
        self.assets = assets
        self.transactions = transactions
        self.valuePoints = valuePoints
        let held = Dictionary(valuePositions.filter(\.held).map { ($0.position, $0) }, uniquingKeysWith: { first, _ in first })
        heldHistory = Dictionary(DepotPosition.make(assets).compactMap { p in
            holdingPositionKey(isin: p.holding.isin, name: p.holding.name).flatMap { held[$0] }.map { (p.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        soldPositions = valuePositions.filter { !$0.held }.sorted { $0.lastDate > $1.lastDate }
    }

    /// The history of a held position.
    func valuePosition(_ p: DepotPosition) -> ValuePosition? { heldHistory[p.id] }
}

enum DepotLoadState {
    case loading
    case failed(String)
    case loaded(DepotData)
}

enum DepotFormat {
    static func percent(_ value: Double, signed: Bool = false, digits: Int = 2) -> String {
        let f = value.formatted(.number.precision(.fractionLength(digits)))
        return (signed && value > 0 ? "+" : "") + f.replacingOccurrences(of: "-", with: "−") + " %"
    }

    static func tint(_ cents: Int64) -> Color { cents > 0 ? Theme.inflow : (cents < 0 ? Theme.negative : Theme.text) }

    static func coverage(_ f: DepotFigure) -> String? {
        f.isPartial ? String(localized: "für \(f.covered) von \(f.total) Positionen") : nil
    }

    static func relative(_ unix: Int64) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = .autoupdatingCurrent
        f.unitsStyle = .full
        return f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(unix)), relativeTo: Date())
    }
}

/// Toolbar switch (macOS) / header switch (iOS) of the depot view.
struct DepotTabPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Picker("Ansicht", selection: $model.depotTab) {
            ForEach(DepotTab.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Positionen, Wertpapieraktivitäten oder Sparpläne (⌘1, ⌘2, ⌘3)")
    }
}

/// A securities depot as a view of its own: value, four depot figures, positions or activities.
/// No cash flow, budgets, booking scopes or booking filters; the search and the sort are the view's own.
/// Layout, building blocks and the rules for changing it: `docs/DEPOT_UND_VERMOEGEN_UI.md`.
struct DepotDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.reportRedaction) private var redaction
    let account: Account

    @State private var load: DepotLoadState = .loading
    @State private var reloadToken = 0
    @State private var query = ""
    @State private var sort = DepotSort()
    @State private var activityFilter = DepotActivityFilter.all
    @State private var activityYear: Int?
    /// The savings plans grid page: 0 = up to now, each step back is one page of months earlier.
    @State private var planPage = 0
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var planPageSize: Int { sizeClass == .compact ? 4 : 6 }
    #else
    private var planPageSize: Int { 6 }
    #endif
    @State private var compositionMode = DepotCompositionMode.position
    /// Positions behind the slice clicked in the composition card (nil: all).
    @State private var compositionFilter: Set<String>?
    @State private var editingClassification: ClassificationEditRequest?
    @State private var historyRequest: PositionHistoryRequest?
    @State private var demoSheetShown = false
    @State private var csvDocument = CSVFileDocument(data: Data())
    @State private var csvFilename = "GiroCrab-Depot"
    @State private var showCSVExporter = false

    private var currency: String { account.currency.isEmpty ? "EUR" : account.currency }

    /// Data of this depot only: while another depot's data is still on its way, nothing is shown.
    private var data: DepotData? {
        if case .loaded(let d) = load, d.accountId == account.id { return d }
        return nil
    }

    private var syncStamp: Int64 {
        model.connections.first { $0.id == account.connectionId }?.lastSyncUnix ?? 0
    }

    /// Anything that can change what the depot shows reloads it: the account's value, a sync, a
    /// classification, the vault itself.
    private var loadKey: String {
        "\(account.id)-\(account.balanceCents)-\(account.balanceDate)-\(model.assetClassificationVersion)-\(syncStamp)-\(model.vaultRevision)-\(reloadToken)"
    }

    var body: some View {
        // The depot has its own search: it never reads or changes the booking list's search or filters.
        AssetAccountFrame(
            searchText: $query,
            searchPrompt: "Wertpapier, ISIN oder WKN",
            top: { tabPicker },
            header: { header },
            metrics: { wide in
                if let data { metrics(data, wide: wide) }
            },
            analysis: {
                if let data, model.depotTab == .positions, !data.assets.isEmpty { analysisSection(data) }
            },
            content: { wide in content(wide: wide) }
        )
        .capturableSheet(item: $editingClassification) { AssetClassificationSheet(request: $0).environment(model) }
        .capturableSheet(item: $historyRequest) { PositionHistorySheet(request: $0).environment(model) }
        .task(id: loadKey) { await reload() }
        .onChange(of: account.id) { activityYear = nil; planPage = 0 }
        // the year menu offers only the years of the period: a new period drops a year it no longer holds
        .onChange(of: model.depotPeriodTitle) { activityYear = nil }
        .onChange(of: planPage) { _, _ in Task { await reloadPlans() } }
        // another width, another page size (iPad split, rotation): start again at the newest page, so no
        // months fall between two pages
        .onChange(of: planPageSize) { _, _ in
            planPage = 0
            Task { await reloadPlans() }
        }
        .fileExporter(isPresented: $showCSVExporter, document: csvDocument, contentType: .commaSeparatedText,
                      defaultFilename: csvFilename) { result in
            if case .failure(let e) = result { model.showError(String(localized: "Export fehlgeschlagen"), e.localizedDescription) }
        }
    }

    // MARK: CSV export (what the table shows: search, period and filter applied)

    private func shownPositions(_ data: DepotData) -> [DepotPosition] {
        let positions = DepotPosition.make(data.assets)
        return DepotPosition.sorted(DepotPosition.filtered(DepotPosition.filtered(positions, query: query), keys: compositionFilter, inventory: positions), by: sort)
    }

    private func shownActivities(_ data: DepotData) -> [SecurityTransaction] {
        let (from, to) = model.depotPeriodRange
        let items = DepotActivities.filtered(data.transactions, accountId: account.id, filter: activityFilter,
                                             query: query, from: from, to: to)
        return DepotActivities.inYear(items, activityYear)
    }

    private func exportCSV(_ data: DepotData) {
        switch model.depotTab {
        case .positions:
            csvDocument = CSVFileDocument(data: Data(DepotCSV.positions(shownPositions(data), currency: currency).utf8))
            csvFilename = DepotCSV.filename(account: account.name, kind: "Positionen")
        case .activities:
            csvDocument = CSVFileDocument(data: Data(DepotCSV.activities(shownActivities(data), currency: currency).utf8))
            csvFilename = DepotCSV.filename(account: account.name, kind: "Aktivitaeten", year: activityYear)
        case .plans:
            return   // the plans have no export
        }
        showCSVExporter = true
    }

    private func exportButton(_ data: DepotData) -> some View {
        HStack {
            Spacer()
            Button { exportCSV(data) } label: { Label("Als CSV exportieren …", systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderless)
                .help("Exportiert, was die Tabelle gerade zeigt (Suche, Zeitraum und Filter)")
        }
    }

    /// iPhone: the tab switch sits in the page (macOS: in the toolbar).
    @ViewBuilder
    private var tabPicker: some View {
        #if os(iOS)
        DepotTabPicker().frame(maxWidth: .infinity)
        #endif
    }

    @ViewBuilder
    private func content(wide: Bool) -> some View {
        if case .failed(let message) = load {
            failure(message)
        } else if let data {
            VStack(alignment: .leading, spacing: 8) {
                // activities: the button sits in their filter row; positions have none
                if model.depotTab == .positions, !data.assets.isEmpty { exportButton(data) }
                switch model.depotTab {
                case .positions: positionsTab(data, wide: wide)
                case .activities: activitiesTab(data, wide: wide)
                case .plans: plansTab(data)
                }
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 30)
        }
    }

    private func reload() async {
        let id = account.id, revision = model.vaultRevision, months = planPageSize, page = planPage
        if case .loaded(let d) = load, d.accountId == id, d.revision == revision {} else { load = .loading }
        do {
            let result = try await model.vaultOffMain { vault in
                (try vault.classifiedAssets(accountId: id), try vault.listSecurityTransactions(accountId: id),
                 try vault.depotValueHistory(accountIds: [id], days: DepotValueHistory.lookbackDays),
                 try vault.depotValuePositions(accountId: id),
                 try vault.depotSavingsPlans(accountId: id, months: UInt32(months), endOffsetMonths: UInt32(page * months)))
            }
            // nil: locked or swapped meanwhile; a cancelled load never replaces newer data
            guard !Task.isCancelled, let result else { return }
            let data = DepotData(accountId: id, revision: revision, assets: result.0, transactions: result.1,
                                 valuePoints: result.2, valuePositions: result.3, plans: result.4)
            load = .loaded(data)
            // paged or resized while this load ran: its plans are of the page it started with
            if page != planPage || months != planPageSize { Task { await reloadPlans() } }
            // (developer) `--demo-sheet position-history`: once, the first position that has a history
            if model.options.demoSheetName == "position-history", !demoSheetShown,
               let p = DepotPosition.make(data.assets).lazy.compactMap({ data.valuePosition($0) }).first {
                demoSheetShown = true
                historyRequest = PositionHistoryRequest(accountId: id, position: p)
            }
        } catch {
            guard !Task.isCancelled else { return }
            load = .failed(describe(error))
        }
    }

    /// Only the savings plans again, after the period changed: the rest of the depot stays as loaded.
    private func reloadPlans() async {
        let id = account.id, revision = model.vaultRevision, page = planPage, months = planPageSize
        guard case .loaded(let d) = load, d.accountId == id, d.revision == revision else { return }
        let plans = try? await model.vaultOffMain {
            try $0.depotSavingsPlans(accountId: id, months: UInt32(months), endOffsetMonths: UInt32(page * months))
        }
        // nil: locked or swapped meanwhile; the depot or the page changed again: this answer is stale
        guard !Task.isCancelled, let plans, page == planPage, months == planPageSize,
              case .loaded(var current) = load, current.accountId == id, current.revision == revision else { return }
        current.plans = plans
        load = .loaded(current)
    }

    private func failure(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Depot konnte nicht geladen werden", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Erneut versuchen") { reloadToken += 1 }
        }
        .padding(.top, 30)
    }

    // MARK: header

    private var header: some View {
        let value = DepotValue.resolve(reportedCents: account.balanceCents, holdings: data?.holdings ?? [])
        return AssetHeaderCard(
            account: account,
            title: account.name,
            valueCents: value.cents,
            valueLabel: value.source == .positionSum ? String(localized: "Summe der Positionen") : String(localized: "Depotwert"),
            periodForDepot: true,
            valueHelp: "Depotwert laut Bank. Das Guthaben des Verrechnungskontos ist nicht enthalten.",
            subtitle: {
                if !account.bankName.isEmpty {
                    Text(account.bankName).appFont(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                statusLine
                if !positionCountText.isEmpty {
                    Text(positionCountText).appFont(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            },
            valueNote: {
                if let diff = value.differenceCents {
                    Text("Positionen: \(Money.format(value.positionSumCents, currency: currency)) (\(Money.signed(diff, currency: currency)) Differenz)")
                        .sensitive(.amounts)
                        .appFont(.caption2, monospacedDigit: true).foregroundStyle(Theme.warning)
                        .multilineTextAlignment(.trailing)
                        .help("Der gemeldete Depotwert und die Summe der Positionen weichen voneinander ab, z. B. durch unterschiedliche Bewertungszeitpunkte.")
                }
            },
            accessory: {
                AssetValueChart(content: valuationHistory, currency: currency,
                                footnote: DepotValueHistory.footnote)
            },
            actions: { EmptyView() }
        )
    }

    private var positionCountText: String {
        guard let data else { return "" }
        return String(localized: "\(data.assets.count) Positionen")
    }

    /// "Bewertung vom 14.11.2026 · Abruf vor 2 Stunden"; each part only when the data has it.
    @ViewBuilder
    private var statusLine: some View {
        let parts = [
            account.balanceDate.isEmpty ? nil : String(localized: "Bewertung vom \(DateText.medium(account.balanceDate))"),
            syncStamp > 0 ? String(localized: "Abruf \(DepotFormat.relative(syncStamp))") : nil,
        ].compactMap { $0 }
        Text(parts.isEmpty ? String(localized: "Noch kein Abruf") : parts.joined(separator: " · "))
            .appFont(.caption).foregroundStyle(Theme.secondary).lineLimit(2)
    }

    // MARK: four figures

    private func metrics(_ data: DepotData, wide: Bool) -> some View {
        let (from, to) = model.depotPeriodRange
        return DepotMetricGrid(
            tiles: DepotKPIs.securities(assets: data.assets, transactions: data.transactions, currency: currency,
                                        periodTitle: model.depotPeriodTitle, from: from, to: to),
            wide: wide)
    }

    // MARK: positions

    @ViewBuilder
    private func positionsTab(_ data: DepotData, wide: Bool) -> some View {
        heldPositions(data, wide: wide)
        let sold = data.soldPositions.filter { matches($0, query: query) }
        if !sold.isEmpty, compositionFilter == nil {
            SoldPositionsSection(positions: sold) { historyRequest = PositionHistoryRequest(accountId: account.id, position: $0) }
        }
    }

    /// A sold position matches the search by name or key (ISIN).
    private func matches(_ p: ValuePosition, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || p.name.localizedCaseInsensitiveContains(q) || p.position.localizedCaseInsensitiveContains(q)
    }

    @ViewBuilder
    private func heldPositions(_ data: DepotData, wide: Bool) -> some View {
        let positions = DepotPosition.make(data.assets)
        let shown = shownPositions(data)
        if data.assets.isEmpty {
            ContentUnavailableView(
                "Keine Positionen",
                systemImage: "chart.line.uptrend.xyaxis",
                description: Text("Positionen kommen mit dem nächsten Abruf. Wertpapiergeschäfte stehen unter „Aktivitäten“, Geldbewegungen als Buchungen im Verrechnungskonto.")
            )
            .padding(.top, 30)
        } else {
            if shown.isEmpty {
                ContentUnavailableView(
                    "Keine Treffer",
                    systemImage: "magnifyingglass",
                    description: Text("Keine Position passt zu „\(redaction.masking(query))“.")
                )
                .padding(.top, 20)
            } else {
                DepotPositionsTable(positions: shown, totalCount: positions.count, sort: $sort, wide: wide,
                                    currency: currency, onClassify: { editingClassification = $0 },
                                    copyAll: { copyToPasteboard(positions.map { HoldingFigures.clipboardLine($0.holding) }.joined(separator: "\n")) })
                    .valueHistory(available: { data.valuePosition($0) != nil },
                                  open: { p in
                                      guard let v = data.valuePosition(p) else { return }
                                      historyRequest = PositionHistoryRequest(accountId: account.id, position: v)
                                  })
            }
        }
    }

    // MARK: composition and history

    @ViewBuilder
    private func analysisSection(_ data: DepotData) -> some View {
        Text("Aktueller Bestand · unabhängig vom gewählten Zeitraum")
            .appFont(.caption).foregroundStyle(Theme.secondary)
            .padding(.horizontal, 4)
        analysis(data)
    }

    @ViewBuilder
    private func analysis(_ data: DepotData) -> some View {
        AssetCompositionCard(assets: data.assets, currency: currency, mode: $compositionMode, filter: $compositionFilter,
                             expandedKey: "depotAnalysisExpanded", displayKey: "depotCompositionDisplay")
    }

    /// The depot's valuation history for the header chart: the values the core holds (the bank's own
    /// reports at each fetch, imported values), cut to the selected period. Before its first value
    /// the depot has none: nothing is drawn there, and nothing is derived from bookings.
    private var valuationHistory: AssetValueChart.Content {
        guard let data else { return .loading }
        return DepotValueHistory.chartContent(data.valuePoints, period: model.depotPeriodRange)
    }

    // MARK: activities

    /// Pages back through the months of the plans grid: always one page is shown, the arrows move it.
    private func planPager(_ data: DepotData) -> some View {
        let months = data.plans?.months ?? []
        let earliest = data.transactions.compactMap { $0.bookingDate.count >= 7 ? String($0.bookingDate.prefix(7)) : nil }.min()
        let canGoBack = (months.first ?? "") > (earliest ?? "")
        return HStack(spacing: 6) {
            Spacer()
            Button { planPage += 1 } label: { Image(systemName: "chevron.left") }
                .disabled(!canGoBack)
                .help("Frühere Monate")
                .accessibilityLabel(Text("Frühere Monate"))
            if let first = months.first, let last = months.last {
                Text("\(DateText.monthLabel(first)) – \(DateText.monthLabel(last))")
                    .appFont(.caption, monospacedDigit: true).foregroundStyle(Theme.secondary)
            }
            Button { planPage -= 1 } label: { Image(systemName: "chevron.right") }
                .disabled(planPage == 0)
                .help("Spätere Monate")
                .accessibilityLabel(Text("Spätere Monate"))
        }
        .buttonStyle(.borderless)
    }

    /// The savings plans of this depot, in the same grid as "Sparpläne & Perks".
    @ViewBuilder
    private func plansTab(_ data: DepotData) -> some View {
        let plans = data.plans.map { DepotPlans.matching($0, query: query) }
        return VStack(alignment: .leading, spacing: 14) {
            planPager(data)
            if let plans, !plans.plans.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    KPI(title: "Monatlich investiert", subtitle: "\(plans.plans.filter(\.active).count) aktive Sparpläne · Rate des letzten Monats",
                        value: Money.format(plans.totalMonthlyCents, currency: currency), tint: Theme.invest)
                    // what the months of this page add up to (the plans' executions in the grid)
                    KPI(title: "Investiert im Zeitraum",
                        subtitle: "\(DateText.monthLabel(plans.months.first ?? "")) – \(DateText.monthLabel(plans.months.last ?? ""))",
                        value: Money.format(plans.plans.flatMap(\.executions).reduce(0) { $0 + $1.amountCents }, currency: currency),
                        tint: Theme.invest)
                }
                .fixedSize(horizontal: false, vertical: true)
                PlanGrid(dashboard: plans, currency: currency)
            } else if !query.isEmpty, data.plans?.plans.isEmpty == false {
                ContentUnavailableView("Keine Treffer", systemImage: "magnifyingglass",
                                       description: Text("Kein Sparplan passt zu „\(redaction.masking(query))“."))
                    .padding(.top, 30)
            } else {
                ContentUnavailableView("Keine Sparpläne erkannt", systemImage: "calendar.badge.clock",
                                       description: Text("In diesem Zeitraum wurden keine wiederkehrenden Sparplan-Käufe erkannt. Sparplan-Ausführungen erscheinen hier, sobald das Depot sie liefert."))
                    .padding(.top, 30)
            }
        }
    }

    @ViewBuilder
    private func activitiesTab(_ data: DepotData, wide: Bool) -> some View {
        let shown = shownActivities(data)
        DepotActivitiesView(all: data.transactions, shown: shown, filter: $activityFilter, year: $activityYear, export: { exportCSV(data) }, query: query,
                            periodTitle: model.depotPeriodTitle, wide: wide)
    }
}
