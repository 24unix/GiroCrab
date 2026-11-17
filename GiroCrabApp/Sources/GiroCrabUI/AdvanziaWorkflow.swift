import Foundation
import GiroCrabCore

/// Owns the job independently of any dialog. Closing a prompt never recreates a login.
@MainActor
@Observable
final class AdvanziaWorkflow {
    enum Phase { case preparing, signingIn, credentials, sms, app, authorizing, importing, failed, finished }
    private(set) var phase = Phase.preparing
    private(set) var session: (any AdvanziaSessionDriving)?
    private(set) var error: String?
    private(set) var submittingCode = false
    var showPrompt = false
    var showBrowser = false
    var target: Int64 = -1
    let connection: BankConnection
    private weak var model: AppModel?
    private let pin: VaultPin
    private let makeSession: @MainActor (AdvanziaProfile, VaultPin, String?) -> any AdvanziaSessionDriving
    private let keychain: AdvanziaKeychainClient
    private var initialPassword: String?
    private var task: Task<Void, Never>?
    private var codeTask: Task<Void, Never>?
    private var automatic = AdvanziaAutomaticImport()
    private var stopped = false
    private var submittedCode = false
    private var authorizationTicks = 0
    private var stalledTicks = 0
    private var previousAuthentication = AdvanziaAuthentication.loading
    var candidates: [Account] {
        let legacy = session?.profile.legacyAccountId
        return model?.accountsByID.values.filter {
            if let legacy { return $0.id == legacy && $0.connectionId == connection.id }
            return $0.kind == .creditCard && $0.connectionId == nil && $0.currency == "EUR" && !$0.isArchived
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } ?? []
    }
    var needsAccountChoice: Bool { session?.profile.hasAccount == false && target < 0 }
    var browser: PortalBrowser? { session?.portal }
    var active: Bool { !stopped && model?.isCurrent(pin) == true }
    var canSubmitCode: Bool { active && phase == .sms && !submittingCode }

    init(connection: BankConnection, model: AppModel, pin: VaultPin,
         password: String? = nil, keychain: AdvanziaKeychainClient = .system,
         makeSession: @escaping @MainActor (AdvanziaProfile, VaultPin, String?) -> any AdvanziaSessionDriving = {
             AdvanziaBrowserSession(profile: $0, pin: $1, savedPassword: $2)
         }) {
        self.connection = connection; self.model = model; self.pin = pin
        self.initialPassword = password
        self.keychain = keychain; self.makeSession = makeSession
    }
    func start() {
        guard task == nil, active else { return }
        task = Task { [weak self] in await self?.run() }
    }
    private func run() async {
        do {
            let id = connection.id
            let profile = try await pin.run { try $0.advanziaProfile(connectionId: id) }
            let keychain = keychain, profileID = profile.profileId
            let password: String?
            do {
                if let supplied = initialPassword { password = supplied; initialPassword = nil }
                else { password = try await Task.detached { try AdvanziaLocalSecrets.read(profileID, using: keychain) }.value }
            }
            catch {
                password = nil
                self.error = String(localized: "Das gespeicherte Passwort ist nicht verfügbar. Öffnen Sie die Bankseite oder prüfen Sie die Zugangseinstellungen.")
                showPrompt = true
            }
            guard active, !Task.isCancelled else { return }
            session = makeSession(profile, pin, password)
            if candidates.isEmpty && profile.legacyAccountId == nil { target = 0 }
            if needsAccountChoice { showPrompt = true }
            phase = .signingIn
            while active && !Task.isCancelled {
                await advance()
                if phase == .finished || stopped { return }
                try await Task.sleep(for: .seconds(1))
            }
        } catch is CancellationError { }
        catch { fail(String(localized: "Advanzia konnte nicht vorbereitet werden. Bitte den Abruf erneut starten.")) }
        if !stopped && !active { cancel() }
    }
    /// One tick is also used by fictional session drivers in regression tests.
    func advance() async {
        guard active, let session, phase != .failed, phase != .finished, !submittingCode else { return }
        await session.tick(loginName: connection.loginName)
        guard active, !Task.isCancelled else { return }
        if let failure = session.error { fail(failure); return }
        if session.ready {
            stalledTicks = 0
            guard !needsAccountChoice else { showPrompt = true; return }
            guard automatic.claim(ready: true, targetSelected: true) else { return }
            await importCapture(session)
            return
        }
        stalledTicks += 1
        if needsAccountChoice { showPrompt = true }
        let auth = session.authentication
        switch auth {
        case .sms:
            if submittedCode {
                phase = .authorizing; authorizationTicks += 1
                if authorizationTicks >= 15 {
                    submittedCode = false; phase = .sms; showPrompt = true
                    self.error = String(localized: "Die SMS-Freigabe wurde noch nicht bestätigt. Prüfen Sie den Code oder öffnen Sie die Bankseite.")
                }
            } else { phase = .sms; showPrompt = true }
        case .app:
            phase = .app
            // A dismissed app hint stays dismissed while the same challenge waits.
            if previousAuthentication != .app { showPrompt = true }
        case .credentials:
            phase = .signingIn
            // Give saved credentials time to submit; never resubmit them in a loop.
            if stalledTicks >= 8 { phase = .credentials; showPrompt = true }
        case .rejected:
            if submittedCode {
                submittedCode = false
                fail(String(localized: "Advanzia hat die Anmeldung oder den Code abgelehnt. Prüfen Sie die Bankseite; GiroCrab wiederholt die Eingabe nicht automatisch."))
            } else {
                phase = .credentials; showPrompt = true
                error = String(localized: "Advanzia hat die Anmeldung abgelehnt. Bitte das Passwort prüfen und erneut bestätigen.")
            }
        case .loading, .method, .unknown:
            phase = submittedCode ? .authorizing : .signingIn
        }
        previousAuthentication = auth
        if stalledTicks >= 120 {
            fail(String(localized: "Die Advanzia-Anmeldung wartet zu lange. Öffnen Sie die Bankseite, um die Freigabe zu prüfen."))
        } else if stalledTicks >= 20 && auth == .unknown {
            fail(String(localized: "Die Advanzia-Anmeldung konnte nicht automatisch fortgesetzt werden. Bei Bedarf können Sie die Bankseite öffnen."))
        }
    }
    func submitCode(_ code: String) {
        guard canSubmitCode, let session, code.range(of: "^[0-9]{4,10}$", options: .regularExpression) != nil else { return }
        submittingCode = true; error = nil
        codeTask = Task { [weak self] in
            guard let self else { return }
            defer { submittingCode = false; codeTask = nil }
            do {
                try await session.submitSMS(code)
                guard active, !Task.isCancelled else { return }
                submittedCode = true; authorizationTicks = 0; phase = .authorizing
            } catch {
                guard active, !Task.isCancelled else { return }
                self.error = String(localized: "Der SMS-Code konnte nicht sicher übermittelt werden. Bitte die Bankseite öffnen und dort bestätigen.")
                phase = .failed; showPrompt = true
            }
        }
    }
    func submitPassword(_ password: String) {
        guard active, phase == .credentials, !submittingCode, !password.isEmpty, let session else { return }
        submittingCode = true; error = nil
        codeTask = Task { [weak self] in
            guard let self else { return }
            defer { submittingCode = false; codeTask = nil }
            do {
                try await session.submitCredentials(loginName: connection.loginName, password: password)
                guard active, !Task.isCancelled else { return }
                stalledTicks = 0; phase = .signingIn
            } catch {
                guard active, !Task.isCancelled else { return }
                self.error = String(localized: "Das Passwort konnte nicht sicher übermittelt werden. Sie können es erneut versuchen oder die Bankseite öffnen.")
                phase = .credentials; showPrompt = true
            }
        }
    }
    private func importCapture(_ session: any AdvanziaSessionDriving) async {
        phase = .importing; error = nil
        if !showBrowser { showPrompt = false }
        do {
            let capture = try await session.collect()
            try Task.checkCancellation()
            guard active, let account = session.accountID else { throw AdvanziaBrowserError(code: "ACCOUNT") }
            let id = connection.id, profileID = session.profile.profileId
            let selected: Int64? = !session.profile.hasAccount && target > 0 ? target : nil
            let summary = try await pin.run { try $0.importAdvanziaCapture(connectionId: id,
                bankAccountId: account, profileId: profileID, jsonBodies: capture.bodies,
                balanceJsonNumber: capture.balance, targetAccountId: selected) }
            await model?.advanziaDidImport(pin: pin)
            guard active, !Task.isCancelled else { return }
            automatic.finish(success: true); phase = .finished
            model?.toast = String(localized: "Advanzia: \(Int(summary.accountsUpdated)) Konten aktualisiert, \(Int(summary.transactionsImported)) neue Buchungen.")
            cancel()
        } catch is CancellationError { }
        catch let e as AdvanziaBrowserError { fail(AdvanziaSecurity.errorMessage(e.code)) }
        catch let e as CoreError {
            if case .InvalidInput(let message) = e { fail(message) }
            else { fail(String(localized: "Advanzia-Import abgebrochen. Bitte Konto-Zuordnung und Umsatzdaten prüfen; es wurden keine unvollständigen Daten übernommen.")) }
        } catch { fail(String(localized: "Advanzia konnte nicht sicher abgerufen werden. Bitte die Bankseite prüfen.")) }
    }
    private func fail(_ message: String) {
        guard active else { return }
        phase = .failed; error = message; showPrompt = true
        automatic.finish(success: false)
    }
    func resumeInBrowser() {
        guard active else { return }
        showBrowser = true; showPrompt = true
        if phase == .failed { phase = .signingIn; automatic.retry(); stalledTicks = 0; submittedCode = false }
    }
    func restart() {
        guard let model else { return }
        cancel()
        model.startAdvanzia(connection)
    }
    func cancel() {
        guard !stopped else { return }
        initialPassword = nil
        stopped = true; task?.cancel(); codeTask?.cancel(); session?.stop()
        showPrompt = false; showBrowser = false
        if model?.advanziaWorkflow === self { model?.advanziaWorkflow = nil }
    }
}
