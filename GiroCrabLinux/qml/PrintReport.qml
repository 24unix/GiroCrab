pragma Singleton
import QtQuick

// PrintReport.swift: the booking printout (GitHub #53). Pure functions on plain
// objects; `html` builds the same markup as the Mac app. Stylesheet and paginator
// (pages, repeated table header, footer) come unchanged from PrintReport.swift via
// build.rs; WebPrinter.qml (QtWebEngine) lays it out like WebKit does on the Mac.
//
// row:     { id, account_id, account_name, date, amount_cents, currency, counterparty, purpose, category, note }
// account: { id, name, iban, balance_cents, balance_date, currency, owner }
// report:  { title, period_label, rows, accounts, daily_balances: {accountId|0: {date: cents}}, generated_at: Date, filter_notes }
// options: { show_category, show_note, show_totals, group_by_account, show_current_balance,
//            show_daily_balance, first_line_only, direction: all|income|expenses, newest_first, logo: off|header|watermark,
//            statement_style (Umsatz-Export, BookingExport.qml: German dates/amounts, owner/IBAN and balances in the header) }
QtObject {
    readonly property var directions: [
        { id: "all", title: qsTr("Einnahmen und Ausgaben") },
        { id: "income", title: qsTr("Nur Einnahmen") },
        { id: "expenses", title: qsTr("Nur Ausgaben") }
    ]
    readonly property var logos: [
        { id: "off", title: qsTr("Kein Logo") },
        { id: "header", title: qsTr("In der Kopfzeile") },
        { id: "watermark", title: qsTr("Als Wasserzeichen") }
    ]
    function directionTitle(d) { const x = directions.find(o => o.id === d); return x ? x.title : "" }
    function includes(direction, cents) { return direction === "income" ? cents > 0 : direction === "expenses" ? cents < 0 : true }

    /// PrintRow.init(_ b: Booking)
    function rowFromBooking(b) {
        const name = b.merchant && b.merchant.name ? b.merchant.name : b.counterparty
        return { id: b.id, account_id: b.account_id, account_name: b.account_name, date: b.booking_date,
                 amount_cents: b.amount_cents, currency: b.currency, counterparty: name,
                 purpose: b.clean_purpose !== "" ? b.clean_purpose : b.purpose,
                 category: b.category_path, note: b.note }
    }

    /// Rows after the direction filter, in print order.
    function rows(list, options) {
        return list.filter(r => includes(options.direction, r.amount_cents)).sort((a, b) => {
            if (a.date !== b.date) return options.newest_first ? (a.date > b.date ? -1 : 1) : (a.date < b.date ? -1 : 1)
            return options.newest_first ? b.id - a.id : a.id - b.id
        })
    }

    function totals(list) {
        let income = 0, expense = 0
        for (const r of list) { if (r.amount_cents > 0) income += r.amount_cents; else expense += r.amount_cents }
        return { income: income, expense: expense, net: income + expense }
    }

    /// "Letzter Monat · Nur Ausgaben · 25 Buchungen": a filtered printout says what it leaves out.
    function metaLine(report, options, count) {
        const parts = [report.period_label]
        const notes = (report.filter_notes || []).slice()
        if (options.direction !== "all") notes.push(directionTitle(options.direction))
        for (const n of notes) if (parts.indexOf(n) < 0) parts.push(n)
        parts.push(qsTr("%1 Buchungen").arg(count))
        return parts.join(" · ")
    }

    /// "Erstellt am 11.11.2026 um 21:45 Uhr" – Umsatzliste omits the time.
    function createdLine(date, statementStyle) {
        if (statementStyle) return qsTr("Erstellt am %1").arg(statementDate(Fmt.iso(date)))
        return qsTr("Erstellt am %1 um %2 Uhr").arg(Fmt.medium(Fmt.iso(date))).arg(date.toLocaleTimeString(Qt.locale(), "HH:mm"))
    }

    /// Fixed German day for export PDFs (independent of the UI language).
    function statementDate(iso) {
        const d = Fmt.date(iso)
        return d ? d.toLocaleDateString(Qt.locale("de_DE"), "dd.MM.yyyy") : iso
    }
    function statementMoney(cents, code) {
        return Number(cents / 100).toLocaleCurrencyString(Qt.locale("de_DE"), Fmt.currencySymbol(code || "EUR")).replace("-", "−")
    }

    /// Opening balance at the start of the first booking day (from end-of-day history).
    function openingBalance(list, endOfDay) {
        const dates = list.map(r => r.date).filter(d => !!d).sort()
        if (!dates.length) return null
        const first = dates[0]
        const sumFirst = list.filter(r => r.date === first).reduce((s, r) => s + r.amount_cents, 0)
        if (endOfDay[first] !== undefined) return { date: first, cents: endOfDay[first] - sumFirst }
        const d = Fmt.date(first)
        d.setDate(d.getDate() - 1)
        const prev = Fmt.iso(d)
        if (endOfDay[prev] !== undefined) return { date: first, cents: endOfDay[prev] }
        return { date: first, cents: 0 }
    }
    /// Closing balance = end-of-day on the last booking day (or opening + sum).
    function closingBalance(list, endOfDay) {
        const dates = list.map(r => r.date).filter(d => !!d).sort()
        if (!dates.length) return null
        const last = dates[dates.length - 1]
        if (endOfDay[last] !== undefined) return { date: last, cents: endOfDay[last] }
        const open = openingBalance(list, endOfDay)
        return open ? { date: last, cents: open.cents + list.reduce((s, r) => s + r.amount_cents, 0) } : null
    }

    function firstLine(s) {
        const l = (s || "").split(/\r?\n/).find(x => x.trim() !== "")
        return l ? l.trim() : ""
    }
    /// Payment reference as printed; empty when it only repeats the payee.
    function displayPurpose(r, firstLineOnly) {
        const p = (firstLineOnly ? firstLine(r.purpose) : (r.purpose || "")).trim()
        const party = (r.counterparty || "").trim()
        return p.localeCompare(party, undefined, { sensitivity: "base" }) === 0 ? "" : p
    }

    /// Escapes for HTML; drops what XML 1.0 forbids (control characters except tab, LF, CR).
    function esc(s) {
        return String(s === null || s === undefined ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;")
            .replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;")
            .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\uFFFE\uFFFF]/g, "")
    }

    function jsString(s) { return JSON.stringify(String(s)).replace(/<\//g, "<\\/") }

    function groupsOf(printed, options) {
        if (!options.group_by_account) return [{ account: null, rows: printed }]
        const order = [], byAccount = {}
        for (const r of printed) {
            if (!byAccount[r.account_id]) { order.push(r.account_id); byAccount[r.account_id] = [] }
            byAccount[r.account_id].push(r)
        }
        order.sort((a, b) => byAccount[a][0].account_name.localeCompare(byAccount[b][0].account_name))
        return order.map(id => ({ account: id, rows: byAccount[id] }))
    }

    /// PrintReport.swift `html(_:options:paper:)`: the Mac markup for a browser engine
    /// (WebPrinter.qml). `assets` = { css, paginator } are read from PrintReport.swift at
    /// build time (build.rs, core call "print_web_assets"), so both apps print the same.
    /// `logoUrl`: image URL for header/watermark.
    function html(report, options, logoUrl, assets) {
        const printed = rows(report.rows, options)
        const groups = groupsOf(printed, options)
        const ids = {}
        for (const r of printed) ids[r.account_id] = true
        const showAccountColumn = !options.group_by_account && Object.keys(ids).length > 1
        const currency = printed.length ? printed[0].currency : "EUR"
        const lang = Qt.locale().name.split("_")[0] || "de"
        let h = "<!doctype html><html lang=\"" + esc(lang) + "\"><head><meta charset=\"utf-8\">\n<title>" + esc(report.title)
              + "</title><style>" + assets.css + "</style></head><body class=\"" + (options.statement_style ? "statement" : "") + "\">\n<div id=\"flow\">\n"
        const logo = logoUrl ? esc(logoUrl) : ""
        if (options.logo === "watermark" && logo) h += "<img class=\"watermark\" src=\"" + logo + "\" alt=\"\">"
        h += "<header>"
        if (options.logo === "header" && logo) h += "<img class=\"logo\" src=\"" + logo + "\" alt=\"GiroCrab\">"
        if (options.statement_style) {
            h += statementHeader(report, printed, options)
        } else {
            h += "<h1>" + esc(report.title) + "</h1>\n<p class=\"meta\">" + esc(metaLine(report, options, printed.length)) + "</p>\n"
               + "<p class=\"meta\">" + esc(createdLine(report.generated_at)) + "</p>\n"
            h += accountSummary(report, options)
        }
        h += "</header>"
        if (!printed.length) h += "<p class=\"empty\">" + esc(qsTr("Keine Buchungen ausgewählt.")) + "</p>"
        for (const g of groups) {
            if (!g.rows.length) continue
            const account = g.account === null ? null : (report.accounts.find(a => a.id === g.account) || null)
            h += "<section>"
            if (options.group_by_account) {
                // Single-account Umsatzliste already titles the account in h1.
                if (!(options.statement_style && groups.length === 1)) {
                    h += "<h2>" + esc(account ? account.name : g.rows[0].account_name)
                    if (account && account.iban)
                        h += " <span class=\"iban\">" + esc(options.statement_style ? Fmt.iban(account.iban) : account.iban) + "</span>"
                    h += "</h2>"
                    if (options.statement_style)
                        h += periodBalanceBlock(g.rows, report.daily_balances[g.account !== null ? g.account : (account ? account.id : 0)] || {},
                                                g.rows[0].currency || currency)
                }
            }
            const balances = options.show_daily_balance ? (report.daily_balances[g.account === null ? 0 : g.account] || {}) : null
            h += table(g.rows, options, showAccountColumn, balances, showAccountColumn)
            if (options.show_totals && !options.statement_style && options.group_by_account && groups.length > 1)
                h += totalsBlock(totals(g.rows), g.rows[0].currency, qsTr("Summe Konto"))
            h += "</section>"
        }
        if (options.show_totals && !options.statement_style && printed.length) h += totalsBlock(totals(printed), currency, qsTr("Summe"))
        h += "</div>"
        const footer = options.statement_style ? createdLine(report.generated_at, true) : report.title + " · " + report.period_label
        const footerMid = options.statement_style ? report.title + " · " + report.period_label : ""
        const bodyClass = options.statement_style ? "paged statement" : "paged"
        const pageOf = qsTr("Seite %1 von %2").arg("{p}").arg("{n}")
        h += "<script>(function(){\nvar W=210, H=297, FOOTER=" + jsString(footer) + ", FOOTERMID=" + jsString(footerMid)
           + ", BODYCLASS=" + jsString(bodyClass) + ", PAGEOF=" + jsString(pageOf) + ";\n"
           + assets.paginator + "</script>"
        h += "</body></html>"
        return h
    }

    /// Account name, owner, IBAN, date range, opening/closing for the Umsatzliste.
    function statementHeader(report, printed, options) {
        const ids = {}
        for (const r of printed) ids[r.account_id] = true
        const accounts = report.accounts.filter(a => ids[a.id]).sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0)
        let h = "<h1>" + esc(report.title) + "</h1>"
        if (accounts.length === 1) {
            const a = accounts[0]
            if (a.owner) h += "<p class=\"owner\">" + esc(a.owner) + "</p>"
            if (a.iban) h += "<p class=\"iban-line\">" + esc(Fmt.iban(a.iban)) + "</p>"
        }
        let meta = report.period_label
        if (options.direction !== "all") meta += " · " + directionTitle(options.direction)
        for (const n of (report.filter_notes || [])) if (meta.indexOf(n) < 0) meta += " · " + n
        meta += " · " + qsTr("%1 Umsätze").arg(printed.length)
        h += "<p class=\"meta\">" + esc(meta) + "</p>"
        if (accounts.length === 1) {
            const eod = report.daily_balances[accounts[0].id] || report.daily_balances[0] || {}
            h += periodBalanceBlock(printed, eod, accounts[0].currency)
        } else if (accounts.length > 1 && !options.group_by_account) {
            h += periodBalanceBlock(printed, report.daily_balances[0] || {}, printed.length ? printed[0].currency : "EUR")
        }
        return h
    }

    /// Anfangssaldo | Endsaldo side by side; labels, dates and amounts share one baseline each.
    function periodBalanceBlock(list, endOfDay, currency) {
        const open = openingBalance(list, endOfDay), close = closingBalance(list, endOfDay)
        if (!open || !close) return ""
        const bal = (label, b) => "\n  <div class=\"bal\">\n    <div class=\"bal-label\">" + esc(label) + "</div>\n"
            + "    <div class=\"bal-date\">" + esc(statementDate(b.date)) + "</div>\n"
            + "    <div class=\"bal-amount\">" + esc(statementMoney(b.cents, currency)) + "</div>\n  </div>"
        return "<div class=\"period-balances\">" + bal(qsTr("Anfangssaldo"), open) + bal(qsTr("Endsaldo"), close) + "\n</div>\n"
    }

    function accountSummary(report, options) {
        if (!options.show_current_balance) return ""
        const ids = {}
        for (const r of report.rows) ids[r.account_id] = true
        const accounts = report.accounts.filter(a => ids[a.id]).sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0)
        if (!accounts.length) return ""
        let h = "<ul class=\"balances\">"
        for (const a of accounts) {
            h += "<li><span class=\"name\">" + esc(a.name) + "</span> <span class=\"value\">" + esc(Fmt.money(a.balance_cents, a.currency)) + "</span>"
            h += " <span class=\"asof\">" + esc(qsTr("Kontostand am %1").arg(Fmt.medium(a.balance_date))) + "</span></li>"
        }
        return h + "</ul>"
    }

    function table(list, options, showAccount, balances, combinedBalance) {
        const day = iso => options.statement_style ? statementDate(iso) : Fmt.medium(iso)
        const money = (cents, code) => options.statement_style ? statementMoney(cents, code) : Fmt.money(cents, code)
        let h = "<table class=\"bookings\"><thead><tr>"
        h += "<th class=\"date\">" + esc(qsTr("Datum")) + "</th>"
        if (showAccount) h += "<th>" + esc(qsTr("Konto")) + "</th>"
        h += "<th>" + esc(qsTr("Empfänger / Verwendungszweck")) + "</th>"
        if (options.show_category) h += "<th>" + esc(qsTr("Kategorie")) + "</th>"
        h += "<th class=\"amount\">" + esc(qsTr("Betrag")) + "</th>"
        if (balances !== null)
            h += "<th class=\"amount\">" + esc(combinedBalance ? qsTr("Tagessaldo (alle Konten)") : qsTr("Tagessaldo")) + "</th>"
        h += "</tr></thead><tbody>"
        for (let i = 0; i < list.length; i++) {
            const r = list[i]
            h += "<tr><td class=\"date\">" + esc(day(r.date)) + "</td>"
            if (showAccount) h += "<td>" + esc(r.account_name) + "</td>"
            const purpose = displayPurpose(r, options.first_line_only)
            h += "<td><div class=\"party\">" + esc(r.counterparty) + "</div>"
            if (purpose !== "") h += "<div class=\"purpose\">" + esc(purpose).replace(/\n/g, "<br>") + "</div>"
            if (options.show_note && r.note) h += "<div class=\"note\">" + esc(r.note) + "</div>"
            h += "</td>"
            if (options.show_category) h += "<td class=\"category\">" + esc(r.category) + "</td>"
            h += "<td class=\"amount\">" + esc(money(r.amount_cents, r.currency)) + "</td>"
            if (balances !== null) {
                const next = i + 1 < list.length ? list[i + 1].date : null
                const prev = i > 0 ? list[i - 1].date : null
                const edge = options.newest_first ? prev !== r.date : next !== r.date
                const value = edge && balances[r.date] !== undefined ? money(balances[r.date], r.currency) : ""
                h += "<td class=\"amount balance\">" + esc(value) + "</td>"
            }
            h += "</tr>"
        }
        return h + "</tbody></table>"
    }

    function totalsBlock(t, currency, label) {
        return "\n<table class=\"totals\"><tbody>\n"
            + "<tr><td>" + esc(qsTr("Einnahmen")) + "</td><td class=\"amount\">" + esc(Fmt.money(t.income, currency)) + "</td></tr>\n"
            + "<tr><td>" + esc(qsTr("Ausgaben")) + "</td><td class=\"amount\">" + esc(Fmt.money(t.expense, currency)) + "</td></tr>\n"
            + "<tr class=\"net\"><td>" + esc(label) + "</td><td class=\"amount\">" + esc(Fmt.money(t.net, currency)) + "</td></tr>\n"
            + "</tbody></table>"
    }
}
