import Foundation
import SwiftUI
import GiroCrabCore

// MARK: - Lastschriften einreichen (#143)

extension AppModel {

    /// Collections can be handed to the bank when the creditor account is a FinTS account.
    var canSubmitDebits: Bool {
        guard let acc = effectiveMandateAccount else { return false }
        return [.volksbankKasselGoettingen, .direkt1822, .finTsGeneric].contains(acc.connector)
            && canSendTransfer(from: acc.id) && activeTransfer == nil
    }

    /// Whether the bank connection of the creditor account has a stored PIN.
    var debitPinStored: Bool {
        guard let acc = effectiveMandateAccount, let id = acc.connectionId else { return false }
        return isDemo || (connectionStatus(id)?.hasPin ?? false)
    }

    /// Starts submitting every built file, one after the other (own TAN each).
    func submitCollection(dueDate: Date, b2bConfirmed: Bool, pin: String) {
        guard let acc = effectiveMandateAccount?.id, !collectionFiles.isEmpty else { return }
        let items = collectionLines.filter(\.included).compactMap { l -> CollectionItem? in
            l.cents.map { CollectionItem(mandateId: l.mandate.id, amountCents: $0, purpose: l.purpose, lastCollection: l.lastCollection) }
        }
        debitRun = DebitRun(accountID: acc, items: items, due: DateText.iso(dueDate),
                            remaining: collectionFiles, total: collectionFiles.count,
                            batchBooking: true, b2bConfirmed: b2bConfirmed, pin: pin)
        mandateError = nil
        withFreshBankingPolicy { [self] in
            if let gate = bankingGate(forAccount: acc) {
                mandateError = gate.message
                debitRun = nil
                return
            }
            startNextDebitGroup()
        }
    }

    private func startNextDebitGroup() {
        guard let vault, let run = debitRun, let file = run.remaining.first,
              let account = allAccounts.first(where: { $0.id == run.accountID }),
              let connection = connections.first(where: { $0.id == account.connectionId }) else { return }
        if !isDemo && !debitPinStored && run.pin.isEmpty {
            mandateError = String(localized: "Bitte die Banking-PIN eingeben.")
            debitRun = nil
            return
        }
        do {
            let ids = Set(file.mandateIds)
            let request = DirectDebitRequest(
                accountId: run.accountID, items: run.items.filter { ids.contains($0.mandateId) },
                collectionDate: run.due, sequence: file.sequence,
                b2bConfirmed: run.b2bConfirmed, batchBooking: run.batchBooking)
            let session = try vault.beginDirectDebit(request: request, secret: isDemo ? "demo" : run.pin, demo: isDemo)
            mandateError = nil
            transferBusy = true
            showCollectionSheet = false
            activeTransferIsDebit = true
            activeTransfer = session
            Task {
                do {
                    self.handleTransfer(try await session.start(), connection: connection)
                } catch {
                    self.finishTransfer(error: error)
                }
            }
        } catch {
            mandateError = describe(error)
            debitRun = nil
        }
    }

    /// One group was accepted: next group, or done.
    func finishDebitGroup(connection: BankConnection) {
        pollTask?.cancel()
        activeChallenge = nil
        activeTransfer = nil
        transferBusy = false
        activeTransferIsDebit = false
        plannedVersion += 1
        mandatesVersion += 1
        guard var run = debitRun else { return }
        run.remaining.removeFirst()
        if run.remaining.isEmpty {
            debitRun = nil
            collectionFiles = []
            toast = String(localized: "Lastschriften eingereicht und unter „Geplant“ vorgemerkt")
            reloadAll()
        } else {
            debitRun = run
            startNextDebitGroup()
        }
    }

    func failDebitRun(_ error: Error) {
        activeTransferIsDebit = false
        debitRun?.pin = ""
        debitRun = nil
        mandateError = describe(error)
        showCollectionSheet = true  // the lines and files are still there
        mandatesVersion += 1
    }

    func debitOutcomeUnknown(reason: String) {
        pollTask?.cancel()
        activeChallenge = nil
        activeTransfer = nil
        transferBusy = false
        activeTransferIsDebit = false
        debitRun = nil
        collectionFiles = []
        mandatesVersion += 1
        mandateError = String(localized: "Ob die Bank den Einzug angenommen hat, ist unklar. Bitte erst im Online-Banking prüfen und die Einzüge nicht erneut einreichen, bevor das geklärt ist.") + " " + reason
        showCollectionSheet = true
    }
}
