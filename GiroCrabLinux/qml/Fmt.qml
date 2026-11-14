pragma Singleton
import QtQuick

// Formatting.swift › enum Money, enum DateText, formatIBAN.
QtObject {
    readonly property var locale: Qt.locale()

    function currencySymbol(code) {
        return ({ "EUR": "€", "USD": "$", "GBP": "£", "CHF": "CHF" })[code || "EUR"] || code
    }
    /// i64 cents -> "1.234,56 €" (U+2212 minus like the Swift app).
    function money(cents, code) {
        const s = Number(cents / 100).toLocaleCurrencyString(locale, currencySymbol(code))
        return s.replace("-", "−")
    }
    /// "+1.234,56 €" for inflows.
    function signed(cents) { return cents > 0 ? "+" + money(cents) : money(cents) }
    function plain(cents) { return Number(cents / 100).toLocaleString(locale, "f", 2).replace("-", "−") }
    function clipboard(cents) { return plain(cents).replace("−", "-") }

    function date(iso) {
        if (!iso) return null
        const p = iso.split("-")
        return new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]))
    }
    function iso(d) {
        const pad = n => (n < 10 ? "0" : "") + n
        return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate())
    }
    function medium(s) { const d = date(s); return d ? d.toLocaleDateString(locale, "dd.MM.yyyy") : s }
    function longDate(s) { const d = date(s); return d ? d.toLocaleDateString(locale, "dddd, d. MMMM yyyy") : s }
    function shortDay(d) { return d.toLocaleDateString(locale, "d. MMM") }

    /// "Heute, 9. November" / "Gestern, 8. November" / "Montag, 2. November" (+ year if not this year).
    function dayHeader(s) {
        const d = date(s)
        if (!d) return s
        const now = new Date()
        const today = new Date(now.getFullYear(), now.getMonth(), now.getDate())
        const dm = d.toLocaleDateString(locale, d.getFullYear() === now.getFullYear() ? "d. MMMM" : "d. MMMM yyyy")
        const diff = Math.round((today - d) / 86400000)
        if (diff === 0) return qsTr("Heute, %1").arg(dm)
        if (diff === 1) return qsTr("Gestern, %1").arg(dm)
        return d.toLocaleDateString(locale, "dddd") + ", " + dm
    }

    /// RelativeDateTimeFormatter (.full): "vor 1 Stunde".
    function relative(unix) {
        const secs = Math.max(0, Date.now() / 1000 - unix)
        const units = [[31536000, "Jahr", "Jahren"], [2592000, "Monat", "Monaten"], [604800, "Woche", "Wochen"],
                       [86400, "Tag", "Tagen"], [3600, "Stunde", "Stunden"], [60, "Minute", "Minuten"]]
        for (const u of units) {
            const n = Math.floor(secs / u[0])
            if (n >= 1) return "vor " + n + " " + (n === 1 ? u[1] : u[2])
        }
        return "gerade eben"
    }

    /// "DE12 3456 …" in blocks of four.
    function iban(s) { return (s || "").replace(/\s+/g, "").replace(/(.{4})/g, "$1 ").trim() }

    /// Search folding: ignores case and diacritics ("Lebensmittel" ≈ "lebensmittel", "Café" ≈ "cafe").
    function fold(s) { return String(s).normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase() }
    function percent(x) { return Math.round(x * 100) + " %" }

    /// Money.parseCents: "280.000,50" / "280,000.50" / "280000.5" → cents (null if invalid).
    /// Both separators: the last one is decimal. One kind: grouping if every group after it has 3 digits.
    function parseCents(input) {
        // U+2212 is the minus `plain` writes, so a prefilled amount parses again
        const t = (input || "").replace(/[€\s']/g, "").replace(/−/g, "-")
        if (t === "") return null
        const used = new Set(t.split("").filter(c => c === "." || c === ","))
        let n = t
        if (used.size === 2) {
            const last = Math.max(t.lastIndexOf("."), t.lastIndexOf(","))
            const dec = t[last], grp = dec === "," ? "." : ","
            n = t.split(grp).join("").replace(dec, ".")
        } else if (used.size === 1) {
            const sep = [...used][0]
            const groups = t.split(sep)
            const localeGrouping = locale.groupSeparator
            const isGrouping = (sep === localeGrouping || groups.length > 2) && groups.slice(1).every(g => g.length === 3)
            n = isGrouping ? groups.join("") : groups.join(".")
        }
        if (!/^-?\d+(\.\d+)?$/.test(n)) return null
        const [i, f] = n.split(".")
        const frac = ((f || "") + "00").slice(0, 2)
        const rest = (f || "").slice(2)
        let cents = Math.abs(parseInt(i, 10)) * 100 + parseInt(frac, 10) + (rest && rest[0] >= "5" ? 1 : 0)
        return n.startsWith("-") ? -cents : cents
    }
    /// ByteCountFormatter(countStyle: .file): powers of 1000, "345 Byte", "12 KB", "1,5 MB", "1,23 GB".
    function byteCount(n) {
        if (n === 0) return qsTr("Null KB")
        if (n < 1000) return n + " Byte"
        if (n < 1e6) return Math.round(n / 1e3) + " KB"
        if (n < 1e9) return Number(n / 1e6).toLocaleString(locale, "f", 1) + " MB"
        return Number(n / 1e9).toLocaleString(locale, "f", 2) + " GB"
    }
    /// A count with grouping: 4820 -> "4.820".
    function count(n) { return Number(n).toLocaleString(locale, "f", 0) }
    /// "2012–2026" (or one year) for an import preview's date range; null without one.
    function yearSpan(p) {
        if (!p || !p.date_range_start || !p.date_range_end) return null
        const a = p.date_range_start.slice(0, 4), b = p.date_range_end.slice(0, 4)
        return a === b ? a : a + "–" + b
    }
    /// PercentText.ppm: "4,99" / "4.99" / "4,99 %" -> 49900 (millionths); null for anything else.
    function percentPpm(input) {
        const t = (input || "").replace(/[%\s]/g, "").replace(/,/g, ".")
        if (!/^[-+]?(\d+\.?\d*|\.\d+)$/.test(t)) return null
        return Math.round(Number(t) * 10000)
    }
    /// PercentText.format: 49900 -> "4,99" (2 to 3 fraction digits, the user's locale).
    function percentText(ppm) {
        const s = Number(ppm / 10000).toLocaleString(locale, "f", 3)
        const dec = locale.decimalPoint
        return s.endsWith("0") && s.indexOf(dec) >= 0 ? s.slice(0, -1) : s
    }
    /// "Jun 26" (DateText.monthLabel) for "2026-06".
    function monthLabel(ym) { const d = date(ym + "-01"); return d ? d.toLocaleDateString(locale, "MMM yy") : ym }
}
