pragma Singleton
import QtQuick

// GiroCode.swift: EPC QR code ("GiroCode", EPC069-12 v002) for a SEPA credit
// transfer, for accounts GiroCrab cannot send from (e.g. PSD2 / Enable Banking
// banks like C24): the user scans it with the bank's app ("Fotoüberweisung").
// The QR matrix comes from the core bridge (`girocode_matrix`, error correction "M").
QtObject {
    /// Max. lengths from EPC069-12.
    readonly property int maxName: 70
    readonly property int maxRemittance: 140
    /// Max. amount: EUR 999,999,999.99.
    readonly property real maxCents: 99999999999

    /// Line breaks of CharacterSet.newlines (incl. U+0085, U+2028, U+2029) become spaces.
    function oneLine(s) { return (s || "").split(/\r\n|[\n\v\f\r\u0085\u2028\u2029]/).join(" ").trim() }
    /// String.prefix(n): counts characters, never cuts a surrogate pair (emoji).
    function prefix(s, n) { return Array.from(s).slice(0, n).join("") }

    /// The QR payload, or null when IBAN, name or amount are unusable.
    function payload(name, iban, bic, amountCents, purpose) {
        iban = (iban || "").toUpperCase().replace(/[^A-Z0-9]/g, "")
        bic = (bic || "").toUpperCase().replace(/[^A-Z0-9]/g, "")
        name = prefix(oneLine(name), maxName)
        const remittance = prefix(oneLine(purpose), maxRemittance)
        if (iban.length < 15 || iban.length > 34 || name === "" || amountCents === null || amountCents < 1 || amountCents > maxCents) return null
        const c = amountCents % 100
        const amount = "EUR" + Math.floor(amountCents / 100) + "." + (c < 10 ? "0" : "") + c
        return [
            "BCD",      // service tag
            "002",      // version (BIC optional within the EEA)
            "1",        // character set: UTF-8
            "SCT",      // SEPA credit transfer
            bic,
            name,
            iban,
            amount,
            "",         // purpose code
            "",         // structured creditor reference (unused: free text below)
            remittance,
        ].join("\n")
    }
}
