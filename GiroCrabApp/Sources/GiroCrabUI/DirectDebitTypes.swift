import Foundation
import GiroCrabCore

// Model data of „Lastschriften“ (GitHub #143).

/// Form state of the mandate sheet (`id` nil = new mandate).
struct MandateDraft: Identifiable {
    let uid = UUID()
    var id: Int64?
    var accountID: Int64
    var name = ""
    var iban = ""
    var bic = ""
    var reference = ""
    var signed = Date()
    var scheme: MandateScheme = .core
    var oneOff = false
    var amountText = ""
    var purpose = ""
    var note = ""
    var active = true

    init(accountID: Int64) { self.accountID = accountID }

    init(_ m: Mandate) {
        id = m.id; accountID = m.accountId; name = m.debtorName; iban = m.debtorIban; bic = m.debtorBic
        reference = m.reference; signed = DateText.date(m.signedDate) ?? Date(); scheme = m.scheme
        oneOff = m.oneOff; amountText = m.defaultAmountCents > 0 ? Money.plain(m.defaultAmountCents) : ""
        purpose = m.defaultPurpose; note = m.note; active = m.active
    }

    var input: MandateInput {
        MandateInput(accountId: accountID, debtorName: name, debtorIban: iban, debtorBic: bic, reference: reference,
                     signedDate: DateText.iso(signed), scheme: scheme, oneOff: oneOff,
                     defaultAmountCents: Money.parseCents(amountText) ?? 0, defaultPurpose: purpose, note: note, active: active)
    }
}

/// One line of the collection sheet.
struct CollectionLine: Identifiable {
    let mandate: Mandate
    var included: Bool
    var amountText: String
    var purpose: String
    /// Last collection under the mandate (`FNAL`).
    var lastCollection = false
    var id: Int64 { mandate.id }
    var cents: Int64? { Money.parseCents(amountText).flatMap { $0 > 0 ? $0 : nil } }
}

/// A collection being handed to the bank: one session (and TAN) per scheme/sequence group.
struct DebitRun {
    let accountID: Int64
    let items: [CollectionItem]
    let due: String
    /// Files still to submit; the first is running. Each carries its own mandates
    /// and sequence type: after one file went through, its mandates change their
    /// sequence, so a position in the run would point at the wrong group.
    var remaining: [DebitFile]
    let total: Int
    let batchBooking: Bool
    let b2bConfirmed: Bool
    var pin: String
    var done: Int { total - remaining.count }
}
