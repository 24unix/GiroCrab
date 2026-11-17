pragma Singleton
import QtQuick

// State and logic of the payment orders beside the single transfer:
// AppModel+Batch.swift / BatchTransferTypes.swift (Sammelüberweisung, #240) and
// AppModel+StandingOrders.swift / StandingOrderTypes.swift (Daueraufträge, #496).
// Both run as a TransferSession of the core, driven by the TAN/PIN flow of
// AppModel.qml › MARK: - SEPA-Überweisung (handleTransfer, cancelTransfer, …), which
// calls back here through `activeTransferIsBatch` / `activeTransferIsStanding`.
QtObject {
    id: p

    /// Bumped when a payment reached the bank: „Geplant“ reloads (AppModel.plannedVersion).
    property int plannedVersion: 0

    // MARK: - Sammelüberweisung (AppModel+Batch.swift)

    property bool showBatchSheet: false
    /// BatchDraft without the rows (they live in `batchRows`, so editing a cell keeps its field).
    property var batchDraft: newBatchDraft(null)
    /// BatchDraft.rows: { rowKey, name, iban, bic, amountText, purpose, cents (0 = invalid), ibanValid }.
    property ListModel batchRows: ListModel {}
    /// Bumped on every row change: totals and counts bind to it.
    property int batchRevision: 0
    property int rowSeq: 0
    /// BatchDraft.remove / restore: removed rows for Strg+Z (Bearbeiten › Widerrufen), newest last.
    property var batchUndo: []

    function newBatchDraft(accountID) {
        const t = new Date(); t.setHours(0, 0, 0, 0); t.setDate(t.getDate() + 1)
        return { account_id: accountID === undefined ? null : accountID,
                 // false = one booking for the sum, true = one booking per payment.
                 singleBookings: false, scheduled: false, executionDate: t, pin: "",
                 // Result of the last CSV import ("12 Zahlungen aus „datei.csv“ übernommen").
                 importNote: "" }
    }
    function setBatch(patch) { batchDraft = Object.assign({}, batchDraft, patch) }
    function batchExecutionDateISO() { return batchDraft.scheduled ? Fmt.iso(batchDraft.executionDate) : null }

    /// BatchRow with `cents` and `ibanValid` worked out once (not on every repaint).
    function batchRow(r) {
        const row = { rowKey: ++rowSeq, name: r.name || "", iban: r.iban || "", bic: r.bic || "",
                      amountText: r.amountText || "", purpose: r.purpose || "" }
        return Object.assign(row, rowChecks(row))
    }
    function rowChecks(r) {
        const c = r.amountText.trim() === "" ? null : AppModel.parseCents(r.amountText)
        return { cents: c !== null && c > 0 ? c : 0, ibanValid: r.iban !== "" && AppModel.validateIban(r.iban) }
    }
    /// BatchRow.isValid
    function rowIsValid(r) {
        const n = r.name.trim()
        return n !== "" && n.length <= 70 && r.ibanValid && r.cents > 0 && r.purpose.length <= 140
    }
    /// A plain copy of row `i` (a ListModel item is not a plain object).
    function rowAt(i) {
        const r = batchRows.get(i)
        return { rowKey: r.rowKey, name: r.name, iban: r.iban, bic: r.bic, amountText: r.amountText, purpose: r.purpose,
                 cents: r.cents, ibanValid: r.ibanValid }
    }
    function updateBatchRow(index, patch) {
        if (index < 0 || index >= batchRows.count) return
        const r = Object.assign(rowAt(index), patch)
        if (patch.iban !== undefined) r.iban = AppModel.groupedIBAN(r.iban)
        Object.assign(r, rowChecks(r))
        for (const k of ["name", "iban", "bic", "amountText", "purpose", "cents", "ibanValid"]) batchRows.setProperty(index, k, r[k])
        batchRevision++
    }
    function addBatchRow() { batchRows.append(batchRow({})); batchRevision++ }
    function setBatchRows(rows) {
        batchRows.clear()
        for (const r of rows) batchRows.append(r)
        batchUndo = []
        batchRevision++
    }
    /// BatchDraft.remove(_:undo:)
    function removeBatchRows(keys) {
        const removed = []
        for (let i = batchRows.count - 1; i >= 0; --i) {
            const r = batchRows.get(i)
            if (keys[r.rowKey]) { removed.unshift({ index: i, row: rowAt(i) }); batchRows.remove(i) }
        }
        if (!removed.length) return
        batchUndo = batchUndo.concat([removed])
        batchRevision++
    }
    /// BatchDraft.restore: Strg+Z puts the rows back where they were.
    function undoBatchRemoval() {
        if (!batchUndo.length) return
        const removed = batchUndo[batchUndo.length - 1]
        batchUndo = batchUndo.slice(0, -1)
        for (const e of removed) batchRows.insert(Math.min(e.index, batchRows.count), e.row)
        batchRevision++
    }
    function batchRowList() {
        void batchRevision
        const out = []
        for (let i = 0; i < batchRows.count; ++i) out.push(rowAt(i))
        return out
    }
    readonly property int batchInvalidCount: { void batchRevision; let n = 0; for (let i = 0; i < batchRows.count; ++i) if (!rowIsValid(batchRows.get(i))) n++; return n }
    readonly property real batchTotalCents: { void batchRevision; let s = 0; for (let i = 0; i < batchRows.count; ++i) s += batchRows.get(i).cents; return s }

    /// FinTS accounts a batch transfer can be sent from (HKCCM; not bunq).
    readonly property var batchAccounts: { void AppModel.bankingPolicy
        return AppModel.transferAccounts.filter(a => a.connector !== "Bunq" && AppModel.bankingGateForAccount(a.id) === null) }
    readonly property bool canBatchTransfer: AppModel.canTransfer && batchAccounts.length > 0

    function sidebarAccountID() {
        const s = AppModel.sidebarSelection
        return s.startsWith("account:") ? Number(s.slice(8)) : null
    }
    function openBatchTransfer() {
        if (!canBatchTransfer) return
        const offered = batchAccounts
        if (batchDraft.account_id === null || !offered.some(a => a.id === batchDraft.account_id)) {
            const selected = sidebarAccountID()
            setBatch({ account_id: offered.some(a => a.id === selected) ? selected : offered[0].id })
        }
        if (batchRows.count === 0) addBatchRow()
        AppModel.transferError = ""
        showBatchSheet = true
    }
    /// Segmented control of the batch sheet: back to the single transfer form.
    function switchToSingleTransfer() {
        showBatchSheet = false
        AppModel.transferError = ""
        Qt.callLater(AppModel.openTransfer)
    }
    /// Segmented control of the single form: on to the batch sheet.
    function switchToBatchTransfer() {
        AppModel.showTransferSheet = false
        Qt.callLater(openBatchTransfer)
    }
    function cancelBatchSheet() {
        showBatchSheet = false
        setBatch({ pin: "" })
        AppModel.transferError = ""
    }

    /// importBatchCSV: replaces empty rows with the file's rows, else appends.
    function importBatchCSV(url) {
        const path = AppModel.localPath(url)
        const fileName = path.split("/").pop()
        AppModel.coreAsync("read_batch_csv", { path: path }, result => {
            if (result.problems.length) { AppModel.transferError = result.problems[0]; return }
            AppModel.transferError = ""
            const imported = result.rows.map(r => batchRow({ name: r.name, iban: AppModel.groupedIBAN(r.iban), bic: r.bic,
                                                            amountText: r.amount_text, purpose: r.purpose }))
            for (let i = batchRows.count - 1; i >= 0; --i) {
                const r = batchRows.get(i)
                if (r.name === "" && r.iban === "" && r.amountText === "" && r.purpose === "") batchRows.remove(i)
            }
            for (const r of imported) batchRows.append(r)
            batchRevision++
            const faulty = imported.filter(r => !rowIsValid(r)).length
            let note = faulty === 0
                ? qsTr("%1 Zahlungen aus „%2“ übernommen").arg(imported.length).arg(fileName)
                : qsTr("%1 Zahlungen aus „%2“ übernommen, %3 fehlerhaft").arg(imported.length).arg(fileName).arg(faulty)
            const doubles = duplicatePaymentCount(batchRowList())
            if (doubles > 0) note += " · " + qsTr("%1 mögliche Doppelte (gleicher Empfänger, Betrag und Zweck)").arg(doubles)
            setBatch({ importNote: note })
        }, err => { AppModel.transferError = AppModel.parseCoreError(err).message })
    }
    /// Rows that repeat an earlier row's IBAN, amount and purpose (a file imported twice,
    /// or the same member listed twice).
    function duplicatePaymentCount(rows) {
        const seen = {}
        let doubles = 0
        for (const r of rows) {
            if (r.iban === "" || r.amountText === "") continue
            const key = [r.iban.replace(/\s/g, "").toUpperCase(), r.amountText.trim(), r.purpose.trim()].join("|")
            if (seen[key]) doubles++
            seen[key] = true
        }
        return doubles
    }

    function startBatch() {
        AppModel.withFreshBankingPolicy(() => {
            const gate = AppModel.bankingGateForAccount(batchDraft.account_id)
            if (gate) { AppModel.transferError = gate.message; return }
            startBatchChecked()
        })
    }
    function startBatchChecked() {
        const d = batchDraft
        const target = sessionTarget(d.account_id, d.pin)
        if (!target) return
        const rows = batchRowList()
        const payments = []
        for (const r of rows) {
            let cents
            try { cents = AppModel.core("parse_amount_to_cents", { text: r.amountText }) } catch (e) { AppModel.transferError = e.message; return }
            const bic = r.bic.trim()
            payments.push({ name: r.name, iban: r.iban, bic: bic === "" ? null : bic, amount_cents: cents, purpose: r.purpose })
        }
        const request = { account_id: d.account_id, payments: payments, batch_booking: !d.singleBookings,
                          execution_date: batchExecutionDateISO() }
        let session
        try { session = AppModel.core("begin_batch_transfer", { request: request, secret: AppModel.isDemo ? "demo" : d.pin, demo: AppModel.isDemo }) }
        catch (e) { AppModel.transferError = e.message; return }
        showBatchSheet = false
        AppModel.runPaymentSession(session, target.connection, "batch")
    }
    /// The account's login, or null (with the PIN prompt's error) when it cannot send now.
    function sessionTarget(accountID, pin) {
        if (accountID === null || !AppModel.canSendTransfer(accountID)) return null
        const account = AppModel.accountsByID[accountID]
        const connection = account ? AppModel.connections.find(c => c.id === account.connection_id) : null
        if (!connection) return null
        const st = AppModel.connectionStatus(connection.id)
        if (!AppModel.isDemo && !(st && st.has_pin) && pin === "") {
            AppModel.transferError = qsTr("Bitte die Banking-PIN eingeben.")
            return null
        }
        return { account: account, connection: connection }
    }
    /// After a batch was sent: empty form, same account.
    function resetBatchDraft() {
        batchDraft = newBatchDraft(batchDraft.account_id)
        setBatchRows([batchRow({})])
    }
    /// finishTransfer for a batch: nothing is lost, the rows are still there.
    function failBatch() {
        setBatch({ pin: "" })
        showBatchSheet = true
    }
    /// cancelSync for a batch (#533): the batch sheet comes back with a notice.
    function cancelBatchRun() {
        setBatch({ pin: "" })
        AppModel.transferError = qsTr("Sammelüberweisung abgebrochen – es wurde nichts gesendet, solange die TAN nicht bestätigt wurde.")
        showBatchSheet = true
    }

    /// BatchRow.samples: fictional members with valid German IBANs; rows 7 and 31 are
    /// faulty on purpose (`--demo-sheet batch-transfer`).
    function sampleBatchRows(n) {
        const names = ["Anna Becker", "Jonas Fischer", "Mia Schneider", "Lukas Wagner", "Sophie Hoffmann", "Paul Keller",
                       "Lena Richter", "Noah Wolf", "Emma Schröder", "Finn Neumann"]
        const sampleIBAN = i => {
            const bban = "37040044" + String(532013000 + i * 7919).padStart(10, "0")
            let m = 0
            for (const ch of bban + "131400") m = (m * 10 + Number(ch)) % 97
            return "DE" + String(98 - m).padStart(2, "0") + bban
        }
        const rows = []
        for (let i = 0; i < n; ++i) {
            let iban = sampleIBAN(i)
            if (i === 6) iban = iban.slice(0, -2) + "99"
            rows.push(batchRow({ name: names[i % names.length], iban: AppModel.groupedIBAN(iban),
                                 amountText: i === 30 ? "" : (i % 4 === 0 ? "60,00" : "30,00"),
                                 purpose: "Mitgliedsbeitrag 2026 Nr. " + (1000 + i) }))
        }
        return rows
    }

    // MARK: - Daueraufträge (AppModel+StandingOrders.swift)

    property bool showStandingSheet: false
    property var standingDraft: newStandingDraft()
    /// What the account's bank allows (StandingOrderLimits), null = unknown / no limits.
    property var standingLimits: null
    /// Stored orders (list_standing_orders), loaded on demand and by „Geplant“.
    property var standingOrders: []
    /// The bank's answer was unclear: the alert "Status des Dauerauftrags unklar".
    property var standingUnknown: null
    property int limitsGeneration: 0

    function startOfDay(d) { const x = new Date(d); x.setHours(0, 0, 0, 0); return x }
    function addDays(d, n) { const x = startOfDay(d); x.setDate(x.getDate() + n); return x }
    function daysInMonth(d) { return new Date(d.getFullYear(), d.getMonth() + 1, 0).getDate() }
    /// 1 = Monday … 7 = Sunday.
    function isoWeekday(d) { return (d.getDay() + 6) % 7 + 1 }
    function tomorrow() { return addDays(new Date(), 1) }

    /// StandingDraft()
    function newStandingDraft() {
        const first = tomorrow()
        const last = new Date(first); last.setFullYear(last.getFullYear() + 1)
        return { action: "Create", orderRowID: null, account_id: null, name: "", iban: "", bic: "", amountText: "", purpose: "",
                 firstDate: first, hasEnd: false, lastDate: last,
                 /// `M` (months) or `W` (weeks).
                 unit: "M", interval: 1,
                 /// Day of the month (31 = last day) or weekday (1 = Monday … 7).
                 execDay: first.getDate(), pin: "" }
    }
    function copyDraft(d) { return Object.assign({}, d, { firstDate: new Date(d.firstDate), lastDate: new Date(d.lastDate) }) }
    function standingCents(d) { const c = AppModel.parseCents(d.amountText); return c !== null && c > 0 ? c : null }

    /// StandingDraft(order:action:): an existing order as a draft (change or delete).
    function draftFromOrder(o, action) {
        const d = newStandingDraft()
        Object.assign(d, { action: action, orderRowID: o.id, account_id: o.account_id, name: o.recipient_name,
                           iban: AppModel.groupedIBAN(o.recipient_iban), amountText: Fmt.plain(o.amount_cents), purpose: o.purpose,
                           firstDate: Fmt.date(o.first_date) || tomorrow(), unit: o.time_unit, interval: o.interval, execDay: o.exec_day })
        const last = o.last_date ? Fmt.date(o.last_date) : null
        if (last) { d.hasEnd = true; d.lastDate = last }
        // the stored start lies in the past: the next date on the order's day
        if (action === "Change") syncDate(d, null)
        return d
    }
    /// StandingDraft(booking:series:accountID:): same recipient, amount and purpose, the rhythm of
    /// its recurring series (monthly when none is known), on the booking's day of the month.
    function draftFromBooking(b, series, accountID) {
        const d = newStandingDraft()
        d.account_id = accountID
        d.name = b.counterparty === "" ? b.merchant_name : b.counterparty
        d.iban = AppModel.groupedIBAN(b.counterparty_iban)
        d.amountText = Fmt.plain(Math.abs(b.amount_cents))
        d.purpose = recurringPurpose(b.purpose || "").slice(0, 140)
        const iv = series ? series.interval : ""
        d.interval = iv === "Quarterly" ? 3 : iv === "HalfYearly" ? 6 : iv === "Yearly" ? 12 : 1
        const booked = Fmt.date(b.booking_date)
        const day = booked ? booked.getDate() : new Date().getDate()
        d.execDay = day >= 31 ? 31 : day
        d.firstDate = nextOccurrence(day, new Date())
        d.lastDate = new Date(d.firstDate); d.lastDate.setFullYear(d.lastDate.getFullYear() + 1)
        return d
    }

    /// StandingDraft.recurringPurpose: the purpose without what changes from payment to payment
    /// (dates, month names, years). Customer and contract numbers stay. Nothing left: the original.
    function recurringPurpose(text) {
        const months = "januar|februar|märz|maerz|april|mai|juni|juli|august|september|oktober|november|dezember"
            + "|january|february|march|may|june|july|october|december"
        const patterns = [
            /\b\d{4}-\d{2}-\d{2}\b/gi,                  // 2026-11-03
            /\b\d{1,2}\.\d{1,2}\.(?:\d{4}|\d{2})?(?!\d)/gi, // 03.11.2026, 03.11.26, 03.11.
            /\b\d{1,2}\/\d{4}\b/gi,                     // 11/2026
            /\b\d{1,2}\.\d{4}\b/gi,                     // 11.2026
            new RegExp("(^|[^A-Za-zÀ-ÿ0-9_])(?:" + months + ")(?![A-Za-zÀ-ÿ0-9_])", "gi"), // November
            /\b20\d{2}\b/gi,                            // 2026
        ]
        let out = text
        for (const re of patterns) out = out.replace(re, (m, lead) => (typeof lead === "string" ? lead : "") + " ")
        out = out.split(/\s+/).filter(x => x !== "").join(" ")
        out = out.replace(/^[ \-–,.;:\/+]+|[ \-–,.;:\/+]+$/g, "")
        // A preposition that pointed at the dropped date ("… vom 03.11.").
        out = out.replace(/\s+(?:vom|am|für|zum|im|ab|bis|per|für den|for|on)$/i, "")
        return out === "" ? text.trim() : out
    }
    /// The first date after `today` on `day` of a month; in a shorter month the last day.
    function nextOccurrence(day, today) {
        const start = startOfDay(today)
        for (let m = 0; m < 3; ++m) {
            const month = new Date(start.getFullYear(), start.getMonth() + m, 1)
            const date = new Date(month.getFullYear(), month.getMonth(), Math.min(day, daysInMonth(month)))
            if (date > start) return date
        }
        return tomorrow()
    }

    /// Whether the first execution falls on the execution day (the bank refuses a schedule that does not add up).
    function firstDateMatchesDay(d) {
        if (d.unit === "W") return isoWeekday(d.firstDate) === d.execDay
        const day = d.firstDate.getDate(), length = daysInMonth(d.firstDate)
        if (d.execDay >= 31) return day === length
        return day === d.execDay || (d.execDay > length && day === length)
    }
    /// The date changed: the execution day follows it.
    function syncDay(d, l) {
        if (firstDateMatchesDay(d)) return
        d.execDay = d.unit === "W" ? isoWeekday(d.firstDate) : d.firstDate.getDate()
        // a day the bank does not allow moves to the nearest allowed one, and the date after it
        conform(d, l)
    }
    /// The execution day changed: the first execution moves to the next date on it.
    function syncDate(d, l) {
        if (firstDateMatchesDay(d)) return
        const before = addDays(firstDateRange(l).from, -1)
        if (d.unit === "W") {
            for (let i = 1; i <= 7; ++i) {
                const x = addDays(before, i)
                if (isoWeekday(x) === d.execDay) { d.firstDate = x; return }
            }
        } else {
            d.firstDate = nextOccurrence(d.execDay, before)
        }
    }
    /// Intervals the bank offers for the chosen unit (empty = any 1…99).
    function allowedIntervals(d, l) { return l ? (d.unit === "W" ? l.weeks : l.months) : [] }
    /// Execution days the bank offers for the chosen unit (empty = any).
    function allowedDays(d, l) { return l ? (d.unit === "W" ? l.weekdays : l.days_of_month) : [] }
    /// Earliest and latest first execution the bank accepts (never before tomorrow); `to` null = open.
    function firstDateRange(l) {
        const start = startOfDay(new Date())
        const from = addDays(start, Math.max(1, l ? l.min_days_ahead : 1))
        const to = l && l.max_days_ahead > 0 ? addDays(start, l.max_days_ahead) : null
        return { from: from, to: to !== null && to < from ? from : to }
    }
    /// Moves values the bank does not allow to the nearest allowed one, so the form never
    /// shows a combination it would refuse.
    function conform(d, l) {
        const intervals = allowedIntervals(d, l)
        if (intervals.length && intervals.indexOf(d.interval) < 0) d.interval = intervals[0]
        const days = allowedDays(d, l)
        if (days.length && days.indexOf(d.execDay) < 0)
            d.execDay = days.reduce((best, x) => Math.abs(x - d.execDay) < Math.abs(best - d.execDay) ? x : best, days[0])
        const range = firstDateRange(l)
        if (d.firstDate < range.from) d.firstDate = range.from
        if (range.to !== null && d.firstDate > range.to) d.firstDate = range.to
        if (!firstDateMatchesDay(d)) syncDate(d, l) // the execution day (snapped above) decides
        if (d.lastDate < d.firstDate) d.lastDate = new Date(d.firstDate)
    }
    /// What the editor still needs before it can go to the review.
    function standingIsValid(d) {
        const n = d.name.trim()
        return d.account_id !== null && n !== "" && n.length <= 70 && AppModel.validateIban(d.iban) && standingCents(d) !== null
            && d.purpose.length <= 140 && (!d.hasEnd || d.lastDate >= d.firstDate) && d.interval >= 1 && d.interval <= 99
            && firstDateMatchesDay(d)
    }
    /// "monatlich", "alle 2 Wochen" …, the same words as the planned list.
    function rhythmText(d) {
        if (d.unit === "W") return d.interval <= 1 ? qsTr("wöchentlich") : qsTr("alle %1 Wochen").arg(d.interval)
        if (d.interval <= 1) return qsTr("monatlich")
        if (d.interval === 3) return qsTr("vierteljährlich")
        if (d.interval === 6) return qsTr("halbjährlich")
        if (d.interval === 12) return qsTr("jährlich")
        return qsTr("alle %1 Monate").arg(d.interval)
    }
    /// "am 15." / "am letzten Tag des Monats" / "montags".
    function execDayText(d) {
        if (d.unit === "W") return weekdayName(d.execDay)
        return d.execDay >= 31 ? qsTr("am letzten Tag des Monats") : qsTr("am %1.").arg(d.execDay)
    }
    /// Weekday names for 1 = Monday … 7 = Sunday.
    function weekdayName(day) { return Fmt.locale.dayName(day % 7, Locale.LongFormat) }
    function standingRequest(d) {
        const cents = standingCents(d)
        if (d.account_id === null || cents === null) return null
        const bic = d.bic.trim()
        return { account_id: d.account_id, action: d.action, order_row_id: d.orderRowID,
                 recipient_name: d.name, recipient_iban: d.iban, recipient_bic: bic === "" ? null : bic,
                 amount_cents: cents, purpose: d.purpose, first_date: Fmt.iso(d.firstDate),
                 last_date: d.hasEnd ? Fmt.iso(d.lastDate) : null, time_unit: d.unit,
                 interval: d.interval, exec_day: d.execDay }
    }
    /// Changes the draft; `follow` = "day" (the date changed) or "date" (the day changed),
    /// "unit" (months / weeks) or "conform" fit it to the bank's limits.
    function setStanding(patch, follow) {
        const d = Object.assign(copyDraft(standingDraft), patch)
        if (follow === "day") syncDay(d, standingLimits)
        else if (follow === "date") syncDate(d, standingLimits)
        else if (follow === "conform") conform(d, standingLimits)
        else if (follow === "unit") {
            // Linux: the execution day follows the first execution into the new unit (a day of
            // the month is no weekday), then the bank's limits as on the Mac (.onChange(of: unit))
            d.execDay = d.unit === "W" ? isoWeekday(d.firstDate) : d.firstDate.getDate()
            conform(d, standingLimits)
        }
        if (d.lastDate < d.firstDate) d.lastDate = new Date(d.firstDate)
        standingDraft = d
        if (patch.account_id !== undefined) refreshStandingLimits()
    }

    /// FinTS accounts a standing order can be placed on (HKCDE; not bunq or the other connectors).
    readonly property var standingOrderAccounts: batchAccounts
    readonly property bool canEditStandingOrders: AppModel.canTransfer && standingOrderAccounts.length > 0 && AppModel.activeTransfer === null

    function reloadStandingOrders() {
        const vgen = AppModel.vaultGeneration
        AppModel.coreAsync("list_standing_orders", { account_ids: [] }, r => {
            if (vgen === AppModel.vaultGeneration && AppModel.isUnlocked) standingOrders = r
        }, () => {})
    }
    /// The stored order behind a „Geplant“ row (ids look like `standing-<row>-<date>`), if any.
    function standingOrderFor(payment) {
        if (!payment || payment.kind !== "StandingOrder") return null
        const parts = String(payment.id).split("-")
        if (parts.length < 2 || parts[0] !== "standing") return null
        return standingOrderByID(Number(parts[1]))
    }
    function standingOrderByID(id) {
        let o = standingOrders.find(x => x.id === id)
        if (!o) {
            try { standingOrders = AppModel.core("list_standing_orders", { account_ids: [] }) } catch (e) {}
            o = standingOrders.find(x => x.id === id)
        }
        return o || null
    }

    /// The entry point for „Geplant“ (PlannedPaymentsView), the booking context menu and the
    /// command palette: `mode` "new" (`arg` = account to preselect, optional), "edit" / "delete"
    /// (`arg` = a StandingOrderInfo, its row id or a „Geplant“ row), "fromBooking" (`arg` = booking).
    function openStandingOrder(mode, arg) {
        if (mode === "new") { newStandingOrder(arg === undefined ? null : arg); return }
        if (mode === "fromBooking") { newStandingOrderFrom(arg); return }
        const order = arg === null || arg === undefined ? null
                    : typeof arg === "number" ? standingOrderByID(arg)
                    : arg.recipient_name !== undefined ? arg : standingOrderFor(arg)
        if (!order) return
        if (mode === "edit") editStandingOrder(order)
        else if (mode === "delete") deleteStandingOrder(order)
    }
    function newStandingOrder(accountFilter) {
        if (!canEditStandingOrders) return
        const d = newStandingDraft()
        const selected = accountFilter !== null && accountFilter !== undefined ? accountFilter : sidebarAccountID()
        const offered = standingOrderAccounts
        d.account_id = offered.some(a => a.id === selected) ? selected : offered[0].id
        d.execDay = d.firstDate.getDate()
        openStandingSheet(d)
    }
    /// Outgoing bookings with an IBAN can become a standing order.
    function canMakeStandingOrder(b) {
        return !!b && canEditStandingOrders && b.amount_cents < 0 && AppModel.validateIban(b.counterparty_iban || "")
    }
    /// Opens the form filled from a booking (the booking's account when it can place orders).
    function newStandingOrderFrom(b) {
        if (!canMakeStandingOrder(b)) return
        const offered = standingOrderAccounts
        const account = offered.some(a => a.id === b.account_id) ? b.account_id : offered[0].id
        openStandingSheet(draftFromBooking(b, AppModel.recurringSeries(b), account))
    }
    function editStandingOrder(o) {
        if (!canEditStandingOrders || !o.can_change) return
        openStandingSheet(draftFromOrder(o, "Change"))
    }
    function deleteStandingOrder(o) {
        if (!canEditStandingOrders || !o.can_delete) return
        openStandingSheet(draftFromOrder(o, "Delete"))
    }
    function openStandingSheet(d) {
        standingDraft = d
        standingLimits = null
        AppModel.transferError = ""
        showStandingSheet = true
        refreshStandingLimits()
    }
    /// Loads what the account's bank allows for the order being edited and fits the draft to it.
    function refreshStandingLimits() {
        const account = standingDraft.account_id, action = standingDraft.action
        if (account === null) return
        const gen = ++limitsGeneration
        AppModel.coreAsync("standing_order_limits", { account_id: account, action: action }, l => {
            // The sheet may have moved on to another account meanwhile.
            if (gen !== limitsGeneration || standingDraft.account_id !== account || standingDraft.action !== action) return
            standingLimits = l || null
            const d = copyDraft(standingDraft)
            conform(d, standingLimits)
            standingDraft = d
        }, () => {
            if (gen !== limitsGeneration) return
            standingLimits = null
            const d = copyDraft(standingDraft)
            conform(d, null)
            standingDraft = d
        })
    }
    function cancelStandingSheet() {
        showStandingSheet = false
        standingDraft = Object.assign(copyDraft(standingDraft), { pin: "" })
        AppModel.transferError = ""
    }
    function startStandingOrder() {
        AppModel.withFreshBankingPolicy(() => {
            const gate = AppModel.bankingGateForAccount(standingDraft.account_id)
            if (gate) { AppModel.transferError = gate.message; return }
            startStandingOrderChecked()
        })
    }
    function startStandingOrderChecked() {
        const d = standingDraft
        const request = standingRequest(d)
        if (!request) return
        const target = sessionTarget(d.account_id, d.pin)
        if (!target) return
        let session
        try { session = AppModel.core("begin_standing_order", { request: request, secret: AppModel.isDemo ? "demo" : d.pin, demo: AppModel.isDemo }) }
        catch (e) { AppModel.transferError = e.message; return }
        showStandingSheet = false
        AppModel.runPaymentSession(session, target.connection, "standing")
    }
    /// The bank accepted the order: the list shows the optimistic copy until the next fetch.
    function finishStandingOrder() {
        const action = standingDraft.action
        standingDraft = newStandingDraft()
        plannedVersion++
        reloadStandingOrders()
        AppModel.toast = action === "Change" ? qsTr("Dauerauftrag geändert")
                       : action === "Delete" ? qsTr("Dauerauftrag gelöscht") : qsTr("Dauerauftrag angelegt")
    }
    /// The bank may have executed it: no retry, say so.
    function standingOrderOutcomeUnknown(reason) {
        standingDraft = newStandingDraft()
        plannedVersion++
        reloadStandingOrders()
        standingUnknown = reason
    }
    /// The user cancelled while the bank waited for the TAN: nothing was sent, back to the sheet.
    function cancelStandingOrderRun() {
        standingDraft = Object.assign(copyDraft(standingDraft), { pin: "" })
        AppModel.transferError = qsTr("Dauerauftrag abgebrochen – es wurde nichts gesendet, solange die TAN nicht bestätigt wurde.")
        showStandingSheet = true
    }
    /// An error before the bank accepted anything: back to the sheet, nothing is lost.
    function failStandingOrder() {
        standingDraft = Object.assign(copyDraft(standingDraft), { pin: "" })
        showStandingSheet = true
    }

    /// Another vault's data (demo ↔ own, restore): its standing orders are not this vault's.
    property Connections vaultWatch: Connections {
        target: AppModel
        function onVaultReplaced() { p.standingOrders = []; p.standingUnknown = null }
    }

    /// endBankDialogsForLock: no sheet stays open, no PIN stays in memory, no order list.
    function endForLock() {
        showBatchSheet = false
        showStandingSheet = false
        setBatch({ pin: "" })
        standingDraft = newStandingDraft()
        standingOrders = []
        standingUnknown = null
    }

    // MARK: - `--demo-sheet` (AppModel.swift › presentDemoSheet)

    /// true when `name` is one of the payment sheets (then it is opened here).
    function presentDemoSheet(name) {
        switch (name) {
        case "batch-transfer": case "batch-transfer-confirm": case "batch-transfer-scheduled":
            setBatchRows(sampleBatchRows(50))
            openBatchTransfer()
            if (name === "batch-transfer-scheduled") setBatch({ scheduled: true })
            return true
        case "standing-order-delete": {
            // the demo orders cannot be changed at the bank; the draft only shows what would be deleted
            let orders = []
            try { orders = AppModel.core("list_standing_orders", { account_ids: [] }) } catch (e) {}
            if (orders.length) openStandingSheet(draftFromOrder(orders[0], "Delete"))
            return true
        }
        case "standing-order": case "standing-order-confirm": {
            newStandingOrder(null)
            const d = copyDraft(standingDraft)
            Object.assign(d, { name: "Stadtwerke München", iban: AppModel.groupedIBAN("DE89370400440532013000"),
                               amountText: Fmt.plain(8500), purpose: "Abschlag Strom Kd-Nr 482910", execDay: 3 })
            syncDate(d, null)
            standingDraft = d
            return true
        }
        }
        return false
    }
}
