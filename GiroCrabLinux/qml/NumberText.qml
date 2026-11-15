pragma Singleton
import QtQuick

// TangibleAssetsUI.swift › NumberText: quantities, weights and fineness typed by hand.
QtObject {
    /// One troy ounce in grams (the unit of every metal price).
    readonly property real troyOunceGrams: 31.1034768

    /// "2,5" / "2.5" -> 2.5. With both separators the last one is the decimal
    /// separator ("1.000,5" / "1,000.5"); null for anything else.
    function double(input) {
        let t = String(input).replace(/[\s']/g, "")
        const c = t.lastIndexOf(","), d = t.lastIndexOf(".")
        if (c >= 0 && d >= 0) t = t.split(c > d ? "." : ",").join("")
        t = t.replace(/,/g, ".")
        if (t === "" || (t.match(/\./g) || []).length > 1 || !/^[-+]?(\d+\.?\d*|\.\d+)$/.test(t)) return null
        const v = Number(t)
        return isFinite(v) ? v : null
    }

    /// 2.5 -> "2,5" in the user's locale (up to `digits` decimals, never grouped,
    /// so it reads back with `double`).
    function format(value, digits) {
        const loc = Fmt.locale
        let s = Number(value).toLocaleString(loc, "f", digits === undefined ? 4 : digits).split(loc.groupSeparator).join("")
        if (s.indexOf(loc.decimalPoint) >= 0) s = s.replace(/0+$/, "").replace(new RegExp("\\" + loc.decimalPoint + "$"), "")
        return s
    }
}
