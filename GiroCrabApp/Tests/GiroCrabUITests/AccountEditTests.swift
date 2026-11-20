import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// "Konto bearbeiten": Kontoart, Notiz (#639, #605, #656).
@MainActor
final class AccountEditTests: XCTestCase {
    func testKindChangeMovesAccountBetweenKindGroups() throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        let account = try XCTUnwrap(model.allAccounts.first { $0.kind == .checking })
        model.setAccountKind(account.id, to: .brokerage)
        let group = try XCTUnwrap(model.groups.first { $0.accounts.contains { $0.id == account.id } })
        XCTAssertTrue(group.accounts.allSatisfy { $0.kind == .brokerage || $0.id != account.id })
        XCTAssertEqual(model.accountsByID[account.id]?.kind, .brokerage)
        XCTAssertFalse(model.groups.filter { $0.name == "Girokonten" }.contains { $0.accounts.contains { $0.id == account.id } })
    }

    func testAccountNoteRoundTrip() throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        let id = try XCTUnwrap(model.allAccounts.first).id
        model.setAccountNote("  Zweitkonto  ", for: id)
        XCTAssertEqual(model.accountNote(for: id), "Zweitkonto")
    }

    /// Kontoeinstellungen (#980): what a sync changed while the sheet was open is no edit there.
    func testSavingKeepsWhatASyncChangedWhileTheSheetWasOpen() throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        let original = try XCTUnwrap(model.allAccounts.first)
        // another device renamed the account and wrote a note; the merge reloaded the accounts
        let vault = try XCTUnwrap(model.vault)
        try vault.renameAccount(accountId: original.id, name: "Haushalt")
        try vault.setAccountNote(accountId: original.id, note: "Vom iPad")
        model.reloadAccounts()
        // the sheet still shows what it loaded; only the owner was changed
        model.saveAccountEdits(original, name: original.name, owner: "Anna", kind: original.kind, note: original.note, bankLabel: original.bankLabel)
        let saved = try XCTUnwrap(model.account(for: original.id))
        XCTAssertEqual(saved.name, "Haushalt")
        XCTAssertEqual(saved.note, "Vom iPad")
        XCTAssertEqual(saved.owner, "Anna")
    }

    func testUntrimmedSnapshotDoesNotOverwriteSyncedFields() throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        let base = try XCTUnwrap(model.allAccounts.first)
        var original = base
        original.name = "  \(base.name)  "
        original.owner = "  \(base.owner)  "
        original.note = "  Alt\n"

        let vault = try XCTUnwrap(model.vault)
        try vault.renameAccount(accountId: base.id, name: "Neu per Sync")
        try vault.setAccountNote(accountId: base.id, note: "Vom iPhone")
        model.reloadAccounts()

        // The form submits trimmed versions of the untouched fields while changing only owner.
        model.saveAccountEdits(
            original,
            name: original.name.trimmingCharacters(in: .whitespaces),
            owner: "Anna",
            kind: original.kind,
            note: original.note.trimmingCharacters(in: .whitespacesAndNewlines),
            bankLabel: original.bankLabel
        )
        let saved = try XCTUnwrap(model.account(for: base.id))
        XCTAssertEqual(saved.name, "Neu per Sync")
        XCTAssertEqual(saved.note, "Vom iPhone")
        XCTAssertEqual(saved.owner, "Anna")
    }

    /// #1467: Standard / Eigener Name / Ausblenden map to the stored label and back.
    func testBankLabelChoiceMapsToTheStoredLabel() {
        XCTAssertEqual(BankLabelChoice(nil), .standard)
        XCTAssertEqual(BankLabelChoice(""), .hidden)
        XCTAssertEqual(BankLabelChoice("Haushalt"), .custom)
        XCTAssertNil(BankLabelChoice.standard.label(custom: "Haushalt"))
        XCTAssertEqual(BankLabelChoice.hidden.label(custom: "Haushalt"), "")
        XCTAssertEqual(BankLabelChoice.custom.label(custom: "  Haushalt "), "Haushalt")
    }

    /// #1467: the sidebar shows the user's label, nothing, or the bank name again.
    func testSavedBankLabelReplacesTheBankNameInTheSidebar() throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        let original = try XCTUnwrap(model.allAccounts.first { !$0.bankName.isEmpty })
        let save = { (label: String?) in
            let current = try XCTUnwrap(model.account(for: original.id))
            model.saveAccountEdits(current, name: current.name, owner: current.owner, kind: current.kind, note: current.note, bankLabel: label)
            return try XCTUnwrap(model.account(for: original.id))
        }
        XCTAssertEqual(try save("Haushalt").sidebarBankName, "Haushalt")
        let hidden = try save("")
        XCTAssertEqual(hidden.sidebarBankName, "")
        XCTAssertEqual(hidden.bankName, original.bankName, "the bank name itself stays")
        XCTAssertEqual(try save(nil).sidebarBankName, original.bankName)
    }

    /// #1467: the login's settings tell how many of its accounts show a label of their own.
    func testCountsAccountsOfALoginWithTheirOwnBankLabel() throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        let first = try XCTUnwrap(model.allAccounts.first { $0.connectionId != nil })
        let login = try XCTUnwrap(first.connectionId)
        XCTAssertEqual(model.accountsWithOwnBankLabel(connectionID: login), 0)
        model.saveAccountEdits(first, name: first.name, owner: first.owner, kind: first.kind, note: first.note, bankLabel: "")
        XCTAssertEqual(model.accountsWithOwnBankLabel(connectionID: login), 1)
        let other = try XCTUnwrap(model.allAccounts.first { $0.connectionId != login })
        model.saveAccountEdits(other, name: other.name, owner: other.owner, kind: other.kind, note: other.note, bankLabel: "X")
        XCTAssertEqual(model.accountsWithOwnBankLabel(connectionID: login), 1, "another login's account doesn't count")
    }
}
