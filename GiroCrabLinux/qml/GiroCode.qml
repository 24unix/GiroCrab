pragma Singleton
import QtQuick

// GiroCode.swift: EPC QR code ("GiroCode", EPC069-12 v002) for a SEPA credit
// transfer, for accounts GiroCrab cannot send from (e.g. PSD2 / Enable Banking
// banks like C24): the user scans it with the bank's app ("Fotoüberweisung").
// Payload and QR matrix come from the core bridge (`girocode_payload`,
// `girocode_matrix`, error correction "M").
QtObject {
    /// The QR payload (core: girocode_payload, EPC069-12 limits), or null when IBAN,
    /// name or amount are unusable.
    function payload(name, iban, bic, amountCents, purpose) {
        if (amountCents == null) return null
        return AppModel.coreOrNull("girocode_payload", { name: name || "", iban: iban || "", bic: bic || "",
                                                         amount_cents: amountCents, purpose: purpose || "" })
    }
}
