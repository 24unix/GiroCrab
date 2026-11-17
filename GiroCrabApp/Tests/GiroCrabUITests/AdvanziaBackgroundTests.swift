import XCTest
import GiroCrabCore
@testable import GiroCrabUI

@MainActor
private final class FictionalAdvanziaSession: AdvanziaSessionDriving {
    let profile: AdvanziaProfile
    var portal: PortalBrowser? { nil }
    var accountID: String? = "00000000-0000-4000-8000-000000000001"
    var ready = false
    var error: String?
    var authentication = AdvanziaAuthentication.sms
    var submitted = 0
    var credentialsSubmitted = 0
    var collected = 0
    var stopped = false
    var rejectCollection = false
    init(profile: AdvanziaProfile) { self.profile = profile }
    func tick(loginName: String) async {}
    func submitSMS(_ code: String) async throws { submitted += 1 }
    func submitCredentials(loginName: String, password: String) async throws { credentialsSubmitted += 1 }
    func stop() { stopped = true }
    func collect() async throws -> AdvanziaCapture {
        collected += 1
        if rejectCollection { throw AdvanziaBrowserError(code: "AUTH") }
        return AdvanziaCapture(bodies: [#"{"transactions":[{"amount":-12.34,"currency":"EUR","transactionDate":"2026-11-17T00:00:00","status":"APPROVED","reference":"fictional-ref","uniqueReference":"fictional-ref","merchantName":"FICTIONAL SHOP"}]}"#], balance: "-12.34")
    }
}

@MainActor
final class AdvanziaBackgroundTests: XCTestCase {
    private var model: AppModel!
    private var flow: AdvanziaWorkflow?
    private var fake: FictionalAdvanziaSession!
    private var pin: VaultPin!
    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        await model.merchantStatsTask?.value
        clearBankingBlock() // Only fictional local imports; no bank transport exists in this test.
        pin = try XCTUnwrap(model.pinVault())
        let id = try await pin.run { try $0.addBankConnection(connector: .advanzia, displayName: "Fiktive Karte", loginName: "demo") }
        let connections = try await pin.run { try $0.listBankConnections() }
        let connection = try XCTUnwrap(connections.first { $0.id == id })
        let profile = try await pin.run { try $0.advanziaProfile(connectionId: id) }
        fake = FictionalAdvanziaSession(profile: profile)
        let driver = fake!
        let job = AdvanziaWorkflow(connection: connection, model: model, pin: pin,
            keychain: FakeAdvanziaKeychain().client, makeSession: { _, _, _ in driver })
        model.advanziaWorkflow = job; flow = job
    }
    override func tearDown() async throws {
        flow?.cancel(); flow = nil; model = nil; fake = nil; pin = nil; clearBankingBlock()
    }
    private func started() async throws -> AdvanziaWorkflow {
        let job = try XCTUnwrap(flow)
        job.start()
        for _ in 0..<200 {
            if job.session != nil { return job }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Fictional workflow did not prepare")
        return job
    }
    func testNativeSMSSubmissionContinuesToAutomaticImportExactlyOnce() async throws {
        let job = try await started()
        await job.advance()
        XCTAssertEqual(job.phase, .sms); XCTAssertTrue(job.showPrompt); XCTAssertFalse(job.showBrowser)
        job.target = 0
        job.submitCode("123456"); job.submitCode("123456")
        for _ in 0..<100 where job.submittingCode { await Task.yield() }
        XCTAssertEqual(fake.submitted, 1)
        XCTAssertEqual(job.phase, .authorizing)
        fake.ready = true
        await job.advance(); await job.advance()
        XCTAssertEqual(fake.collected, 1); XCTAssertTrue(fake.stopped)
        XCTAssertNil(job.error, job.error ?? ""); XCTAssertEqual(job.phase, .finished); XCTAssertNil(model.advanziaWorkflow)
        let id = job.connection.id
        let account = try await pin.run { try $0.listAccounts().first { $0.connectionId == id } }
        XCTAssertEqual(account?.balanceCents, -1234)
        XCTAssertNotNil(model.toast)
    }
    func testAppHintCanCloseWithoutCancellingTheSession() async throws {
        fake.authentication = .app
        let job = try await started()
        await job.advance()
        XCTAssertEqual(job.phase, .app); XCTAssertTrue(job.showPrompt)
        job.showPrompt = false
        await job.advance()
        XCTAssertFalse(job.showPrompt); XCTAssertFalse(fake.stopped)
        XCTAssertTrue(job.active); XCTAssertEqual(fake.collected, 0)
    }
    func testExistingSessionImportsWithoutAnyPrompt() async throws {
        // No orphan accounts: the new-account choice is unambiguous.
        model.accountsByID = [:]
        fake.ready = true
        let job = try await started()
        for _ in 0..<200 {
            if job.phase == .finished { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(job.error, job.error ?? ""); XCTAssertEqual(job.phase, .finished); XCTAssertFalse(job.showPrompt)
        XCTAssertEqual(fake.collected, 1)
    }
    func testMissingAccountChoicePreventsAutomaticImport() async throws {
        let job = try await started()
        job.target = -1; fake.ready = true
        await job.advance()
        XCTAssertTrue(job.needsAccountChoice); XCTAssertTrue(job.showPrompt)
        XCTAssertEqual(fake.collected, 0)
    }
    func testFailureDoesNotLoopAndFallbackKeepsTheSameSession() async throws {
        let job = try await started()
        job.target = 0; fake.ready = true; fake.rejectCollection = true
        await job.advance(); await job.advance()
        XCTAssertEqual(job.phase, .failed); XCTAssertEqual(fake.collected, 1)
        XCTAssertNotNil(job.error)
        job.resumeInBrowser()
        XCTAssertTrue(job.showBrowser); XCTAssertFalse(fake.stopped)
        XCTAssertTrue(job.session === fake)
    }
    func testCancellationStopsCodeSubmissionAndFurtherCollection() async throws {
        let job = try await started()
        job.cancel(); job.submitCode("123456"); fake.ready = true
        await job.advance()
        XCTAssertTrue(fake.stopped); XCTAssertEqual(fake.submitted, 0); XCTAssertEqual(fake.collected, 0)
        XCTAssertNil(model.advanziaWorkflow)
    }
    func testCancelAllSyncStopsTheBackgroundJob() async throws {
        let job = try await started()
        model.cancelAllSync()
        XCTAssertFalse(job.active); XCTAssertTrue(fake.stopped)
        XCTAssertNil(model.advanziaWorkflow)
    }
    func testLegacyProfileOffersItsBoundAccountAndWaitsForExplicitChoice() async throws {
        let original = try XCTUnwrap(flow)
        let id = original.connection.id
        let namespace = fake.profile.profileId
        _ = try await pin.run { try $0.importAdvanziaCapture(connectionId: id,
            bankAccountId: "00000000-0000-4000-8000-000000000001", profileId: namespace,
            jsonBodies: [#"{"transactions":[]}"#], balanceJsonNumber: "0", targetAccountId: nil) }
        let accounts = try await pin.run { try $0.listAccounts() }
        let account = try XCTUnwrap(accounts.first { $0.connectionId == id })
        model.accountsByID[account.id] = account
        original.cancel()
        let profile = AdvanziaProfile(profileId: namespace, bankAccountId: nil, hasAccount: false,
            authMethod: "sms", legacyAccountId: account.id)
        let driver = FictionalAdvanziaSession(profile: profile)
        driver.ready = true
        fake = driver
        let job = AdvanziaWorkflow(connection: original.connection, model: model, pin: pin,
            keychain: FakeAdvanziaKeychain().client, makeSession: { _, _, _ in driver })
        model.advanziaWorkflow = job; flow = job
        _ = try await started()
        await job.advance()
        XCTAssertEqual(job.candidates.map(\.id), [account.id])
        XCTAssertTrue(job.needsAccountChoice); XCTAssertTrue(job.showPrompt)
        XCTAssertEqual(job.target, -1); XCTAssertEqual(driver.collected, 0)
    }
    func testMissingPasswordUsesNativePromptInsteadOfOpeningTheBankPage() async throws {
        fake.authentication = .credentials
        let job = try await started()
        for _ in 0..<9 { await job.advance() }
        XCTAssertEqual(job.phase, .credentials); XCTAssertTrue(job.showPrompt); XCTAssertFalse(job.showBrowser)
        job.submitPassword("fictional-one-time-password"); job.submitPassword("duplicate")
        for _ in 0..<100 where job.submittingCode { await Task.yield() }
        XCTAssertEqual(fake.credentialsSubmitted, 1)
        XCTAssertEqual(job.phase, .signingIn); XCTAssertFalse(job.showBrowser)
    }
    func testUnknownPageShowsNativeErrorAndNeverOpensTheBrowserAutomatically() async throws {
        fake.authentication = .unknown
        let job = try await started()
        for _ in 0..<21 { await job.advance() }
        XCTAssertEqual(job.phase, .failed); XCTAssertTrue(job.showPrompt); XCTAssertFalse(job.showBrowser)
        XCTAssertNotNil(job.error)
        job.resumeInBrowser()
        XCTAssertTrue(job.showBrowser)
    }
    func testUnsavedFirstPasswordIsPassedDirectlyToTheSameBackgroundWorkflow() async throws {
        let original = try XCTUnwrap(flow); original.cancel()
        var received: String?
        let driver = fake!
        let brokenKeychain = FakeAdvanziaKeychain(); brokenKeychain.forcedError = errSecAuthFailed
        let job = AdvanziaWorkflow(connection: original.connection, model: model, pin: pin,
            password: "fictional-initial-password", keychain: brokenKeychain.client,
            makeSession: { _, _, password in received = password; return driver })
        model.advanziaWorkflow = job; flow = job
        _ = try await started()
        XCTAssertEqual(received, "fictional-initial-password")
        XCTAssertNil(job.error); XCTAssertFalse(job.showBrowser)
    }
    func testVaultChangeCancelsTheHiddenBrowser() async throws {
        let job = try await started()
        model.releaseVaultState()
        XCTAssertFalse(job.active); XCTAssertTrue(fake.stopped)
        XCTAssertNil(model.advanziaWorkflow)
    }
}
