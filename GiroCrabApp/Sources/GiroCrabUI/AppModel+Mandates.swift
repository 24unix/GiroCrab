import Foundation
import SwiftUI
import GiroCrabCore

// MARK: - Lastschriften (#143)

extension AppModel {
    /// Accounts that can collect: current accounts with an IBAN.
    var debitAccounts: [Account] {
        allAccounts.filter { $0.kind == .checking && !$0.iban.isEmpty && !$0.isArchived }
    }

    /// The creditor account shown: the chosen one, else the one selected in the sidebar
    /// before, else the first.
    var effectiveMandateAccount: Account? {
        debitAccounts.first { $0.id == mandateAccountID } ?? debitAccounts.first
    }

    func reloadMandates() async {
        guard let acc = effectiveMandateAccount?.id else {
            mandates = []; creditorID = ""
            return
        }
        let version = mandatesVersion
        guard let r = try? await vaultOffMain({ v in
            (try v.listMandates(accountId: acc), try v.creditorId(accountId: acc), try v.suggestedCreditorId(),
             try v.openMandateReturns(accountId: acc))
        }) else { return }
        guard acc == effectiveMandateAccount?.id, version == mandatesVersion else { return }
        mandates = r.0
        creditorID = r.1
        suggestedCreditorID = r.2
        openMandateReturns = r.3
        if let s = selectedMandateID, !mandates.contains(where: { $0.id == s }) { selectedMandateID = nil }
    }

    /// Open returns of one mandate, newest first.
    func openReturns(of m: Mandate) -> [MandateBooking] {
        openMandateReturns.filter { $0.mandateId == m.id }
    }

    func loadMandateBookings(_ m: Mandate?) async {
        guard let m else { mandateBookings = []; return }
        let r = try? await vaultOffMain { try $0.mandateBookings(mandateId: m.id) }
        guard selectedMandateID == m.id else { return }
        mandateBookings = r ?? []
    }

    /// The user looked at the returns of this mandate.
    func acknowledgeReturns(_ m: Mandate) {
        Task { @MainActor in
            _ = try? await vaultOffMain { try $0.acknowledgeMandateReturns(mandateId: m.id) }
            mandatesVersion += 1
        }
    }

    /// ↑/↓ in the mandate list; stops at both ends like the booking list.
    func moveMandateSelection(_ delta: Int) {
        guard !mandates.isEmpty else { return }
        let idx = selectedMandateID.flatMap { id in mandates.firstIndex { $0.id == id } } ?? -1
        selectedMandateID = mandates[max(0, min(mandates.count - 1, idx + delta))].id
    }

    func newMandate() {
        guard let acc = effectiveMandateAccount else { return }
        mandateError = nil
        mandateDraft = MandateDraft(accountID: acc.id)
    }

    func editMandate(_ m: Mandate) {
        mandateError = nil
        mandateDraft = MandateDraft(m)
    }

    func saveMandateDraft() {
        guard let draft = mandateDraft else { return }
        let input = draft.input
        let id = draft.id
        Task { @MainActor in
            do {
                guard let saved = try await vaultOffMain({ try $0.saveMandate(id: id, input: input) }) else { return }
                mandateDraft = nil
                mandateError = nil
                selectedMandateID = saved.id
                mandatesVersion += 1
            } catch {
                mandateError = describe(error)
            }
        }
    }

    func setMandateActive(_ m: Mandate, _ active: Bool) {
        var d = MandateDraft(m)
        d.active = active
        let input = d.input
        Task { @MainActor in
            _ = try? await vaultOffMain { try $0.saveMandate(id: m.id, input: input) }
            mandatesVersion += 1
        }
    }

    func deleteMandate(_ m: Mandate) {
        Task { @MainActor in
            _ = try? await vaultOffMain { try $0.deleteMandate(id: m.id) }
            if selectedMandateID == m.id { selectedMandateID = nil }
            mandatesVersion += 1
        }
    }

    /// Saves the creditor ID of the account shown ("" removes it).
    func saveCreditorID(_ text: String) {
        guard let acc = effectiveMandateAccount?.id else { return }
        Task { @MainActor in
            do {
                _ = try await vaultOffMain { try $0.setCreditorId(accountId: acc, creditorId: text) }
                mandateError = nil
            } catch {
                mandateError = describe(error)
            }
            mandatesVersion += 1
        }
    }

    /// A dropped or chosen file: a `pain.008` file (.xml) or a CSV member list.
    func importMandateFile(_ url: URL) {
        url.pathExtension.lowercased() == "xml" ? importPain008(url) : importMandateCSV(url)
    }

    func importPain008(_ url: URL) {
        guard let acc = effectiveMandateAccount?.id else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let xml = String(data: data, encoding: .utf8) else {
            mandateError = String(localized: "Die Datei konnte nicht gelesen werden.")
            return
        }
        let name = url.lastPathComponent
        Task { @MainActor in
            do {
                guard let r = try await vaultOffMain({ try $0.importPain008(accountId: acc, xml: xml) }) else { return }
                mandatesVersion += 1
                var note = String(localized: "„\(name)“: \(r.created) neu, \(r.updated) aktualisiert")
                if !r.failed.isEmpty {
                    note += String(localized: ", \(r.failed.count) nicht übernommen (Zeile \(r.failed[0]))")
                }
                mandateNote = note
                mandateError = nil
            } catch {
                mandateError = describe(error)
            }
        }
    }

    func exportMandates() {
        guard let acc = effectiveMandateAccount?.id else { return }
        Task { @MainActor in
            do {
                guard let csv = try await vaultOffMain({ try $0.exportMandatesCsv(accountId: acc) }) else { return }
                mandateExport = CSVFileDocument(data: Data(csv.utf8))
                showMandateExport = true
            } catch {
                mandateError = describe(error)
            }
        }
    }

    func importMandateCSV(_ url: URL) {
        guard let acc = effectiveMandateAccount?.id else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            mandateError = String(localized: "Die Datei konnte nicht gelesen werden.")
            return
        }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
        let parsed = parseMandateCsv(text: text)
        if let problem = parsed.problems.first {
            mandateError = problem
            return
        }
        let name = url.lastPathComponent
        Task { @MainActor in
            do {
                guard let r = try await vaultOffMain({ try $0.importMandateRows(accountId: acc, rows: parsed.rows) }) else { return }
                mandatesVersion += 1
                var note = String(localized: "„\(name)“: \(r.created) neu, \(r.updated) aktualisiert")
                if !r.failed.isEmpty {
                    note += String(localized: ", \(r.failed.count) nicht übernommen (Zeile \(r.failed[0]))")
                }
                mandateNote = note
                mandateError = nil
            } catch {
                mandateError = describe(error)
            }
        }
    }

    // MARK: Einzug

    func openCollection() {
        let active = mandates.filter(\.active)
        guard !active.isEmpty else { return }
        collectionLines = active.map {
            CollectionLine(mandate: $0, included: true,
                           amountText: $0.defaultAmountCents > 0 ? Money.plain($0.defaultAmountCents) : "",
                           purpose: $0.defaultPurpose)
        }
        collectionFiles = []
        mandateError = nil
        showCollectionSheet = true
    }

    /// Builds the files for the included lines.
    func buildCollection(dueDate: Date) {
        guard let acc = effectiveMandateAccount?.id else { return }
        let items = collectionLines.filter(\.included).compactMap { l -> CollectionItem? in
            l.cents.map { CollectionItem(mandateId: l.mandate.id, amountCents: $0, purpose: l.purpose, lastCollection: l.lastCollection) }
        }
        let due = DateText.iso(dueDate)
        Task { @MainActor in
            do {
                guard let files = try await vaultOffMain({ try $0.buildCollectionFiles(accountId: acc, items: items, collectionDate: due) }) else { return }
                collectionFiles = files
                mandateError = nil
            } catch {
                collectionFiles = []
                mandateError = describe(error)
            }
        }
    }

    /// After the files were handed to the bank: the next collection of these
    /// mandates is a follow-up (`RCUR`).
    func markCollected(_ files: [DebitFile], dueDate: Date) {
        let ids = files.flatMap(\.mandateIds)
        let due = DateText.iso(dueDate)
        Task { @MainActor in
            _ = try? await vaultOffMain { try $0.markCollected(mandateIds: ids, dueDate: due) }
            // after the final collection the mandate is done
            for file in files where file.sequence == "FNAL" {
                for id in file.mandateIds { if let m = mandates.first(where: { $0.id == id }) { setMandateActive(m, false) } }
            }
            showCollectionSheet = false
            collectionFiles = []
            mandatesVersion += 1
        }
    }
}
