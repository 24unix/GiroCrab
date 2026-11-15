import Foundation
import GiroCrabCore

struct BatchRow: Identifiable {
    let id = UUID()
    var name = ""
    var iban = ""
    var bic = ""
    var amountText = ""
    var purpose = ""

    var cents: Int64? {
        guard let c = try? parseAmountToCents(text: amountText), c > 0 else { return nil }
        return c
    }
    var ibanValid: Bool { validateIban(iban: iban) }
    var isValid: Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        return !n.isEmpty && n.count <= 70 && ibanValid && cents != nil && purpose.count <= 140
    }

    init() {}
    init(csv r: BatchCsvRow) {
        name = r.name
        iban = BatchRow.grouped(r.iban)
        bic = r.bic
        amountText = r.amountText
        purpose = r.purpose
    }

    static func grouped(_ s: String) -> String {
        let t = s.filter { !$0.isWhitespace }
        return stride(from: 0, to: t.count, by: 4).map { i in
            let a = t.index(t.startIndex, offsetBy: i)
            return String(t[a..<t.index(a, offsetBy: min(4, t.count - i))])
        }.joined(separator: " ")
    }

    /// Fictional members with valid German IBANs; rows 7 and 31 are faulty on purpose (`--demo-sheet`).
    static func samples(_ n: Int) -> [BatchRow] {
        let names = ["Anna Becker", "Jonas Fischer", "Mia Schneider", "Lukas Wagner", "Sophie Hoffmann", "Paul Keller",
                     "Lena Richter", "Noah Wolf", "Emma Schröder", "Finn Neumann"]
        return (0..<n).map { i in
            var r = BatchRow()
            r.name = names[i % names.count]
            r.iban = grouped(sampleIBAN(i))
            r.amountText = i % 4 == 0 ? "60,00" : "30,00"
            r.purpose = "Mitgliedsbeitrag 2026 Nr. \(1000 + i)"
            if i == 6 { r.iban = grouped(String(sampleIBAN(i).dropLast(2)) + "99") }
            if i == 30 { r.amountText = "" }
            return r
        }
    }

    private static func sampleIBAN(_ i: Int) -> String {
        let bban = "37040044" + String(format: "%010d", 532_013_000 + i * 7919)
        let digits = (bban + "131400").reduce(into: 0) { acc, c in acc = (acc * 10 + Int(String(c))!) % 97 }
        return "DE" + String(format: "%02d", 98 - digits) + bban
    }
}

/// The batch being edited, plus undoable row removal (⌘Z / Bearbeiten › Widerrufen).
@Observable
final class BatchDraft {
    var accountID: Int64?
    var rows: [BatchRow] = [BatchRow()]
    /// false = one booking for the sum, true = one booking per payment.
    var singleBookings = false
    var scheduled = false
    var executionDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    var pin = ""
    /// Result of the last CSV import ("12 Zeilen aus datei.csv · 2 fehlerhaft").
    var importNote: String?

    var executionDateISO: String? {
        guard scheduled else { return nil }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: executionDate)
    }

    func remove(_ ids: Set<BatchRow.ID>, undo: UndoManager?) {
        let removed = rows.enumerated().filter { ids.contains($0.element.id) }.map { ($0.offset, $0.element) }
        guard !removed.isEmpty else { return }
        rows.removeAll { ids.contains($0.id) }
        undo?.registerUndo(withTarget: self) { $0.restore(removed, undo: undo) }
        undo?.setActionName(String(localized: "Zeilen entfernen"))
    }

    private func restore(_ removed: [(Int, BatchRow)], undo: UndoManager?) {
        for (index, row) in removed.sorted(by: { $0.0 < $1.0 }) {
            rows.insert(row, at: min(index, rows.count))
        }
        let ids = Set(removed.map(\.1.id))
        undo?.registerUndo(withTarget: self) { $0.remove(ids, undo: undo) }
        undo?.setActionName(String(localized: "Zeilen entfernen"))
    }
}
