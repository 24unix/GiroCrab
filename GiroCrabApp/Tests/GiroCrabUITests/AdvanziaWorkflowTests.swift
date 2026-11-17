import XCTest
import Security
import GiroCrabCore
@testable import GiroCrabUI

final class FakeAdvanziaKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    var denyDataProtection = true
    var forcedError: OSStatus?
    private func access<T>(_ work: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return work() }
    private func id(_ q: [String: Any]) -> String {
        "\(q[kSecUseDataProtectionKeychain as String] as? Bool ?? true):\(q[kSecAttrAccount as String] as? String ?? "")"
    }
    private func status(_ q: [String: Any]) -> OSStatus? {
        if let forcedError { return forcedError }
        #if os(macOS)
        if denyDataProtection && q[kSecUseDataProtectionKeychain as String] as? Bool == true { return errSecMissingEntitlement }
        #endif
        return nil
    }
    var client: AdvanziaKeychainClient {
        AdvanziaKeychainClient(copy: { q in self.access {
            if let status = self.status(q) { return (status, nil) }
            guard let data = self.items[self.id(q)] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data)
        } }, add: { q in self.access {
            if let status = self.status(q) { return status }
            self.items[self.id(q)] = q[kSecValueData as String] as? Data
            return errSecSuccess
        } }, update: { q, attrs in self.access {
            if let status = self.status(q) { return status }
            guard self.items[self.id(q)] != nil else { return errSecItemNotFound }
            self.items[self.id(q)] = attrs[kSecValueData as String] as? Data
            return errSecSuccess
        } }, delete: { q in self.access {
            if let status = self.status(q) { return status }
            self.items.removeValue(forKey: self.id(q)); return errSecSuccess
        } })
    }
}

@MainActor
final class AdvanziaWorkflowTests: XCTestCase {
    private var model: AppModel!
    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        await model.merchantStatsTask?.value
    }
    override func tearDown() async throws { model = nil }
    func testAutomaticImportWaitsForAuthenticationAndAccountChoice() {
        var flow = AdvanziaAutomaticImport()
        XCTAssertFalse(flow.claim(ready: false, targetSelected: true))
        XCTAssertFalse(flow.claim(ready: true, targetSelected: false))
        XCTAssertTrue(flow.claim(ready: true, targetSelected: true))
        XCTAssertFalse(flow.claim(ready: true, targetSelected: true))
        flow.finish(success: true)
        XCTAssertFalse(flow.claim(ready: true, targetSelected: true))
    }
    func testFailedAutomaticImportDoesNotRetryInALoop() {
        var flow = AdvanziaAutomaticImport()
        XCTAssertTrue(flow.claim(ready: true, targetSelected: true))
        flow.finish(success: false)
        XCTAssertFalse(flow.claim(ready: true, targetSelected: true))
        flow.retry()
        XCTAssertTrue(flow.claim(ready: true, targetSelected: true))
    }
    func testUnsignedBuildFallbackUpdatesAndDeletesOnlyItsOwnProfile() throws {
        let fake = FakeAdvanziaKeychain(), client = fake.client
        let a = "00000000-0000-4000-8000-000000000001", b = "00000000-0000-4000-8000-000000000002"
        try AdvanziaLocalSecrets.save(password: "invented-a", for: a, using: client)
        try AdvanziaLocalSecrets.save(password: "invented-b", for: b, using: client)
        XCTAssertEqual(try AdvanziaLocalSecrets.read(a, using: client), "invented-a")
        try AdvanziaLocalSecrets.save(password: "invented-new", for: a, using: client)
        XCTAssertEqual(try AdvanziaLocalSecrets.read(a, using: client), "invented-new")
        try AdvanziaLocalSecrets.delete(a, using: client)
        XCTAssertFalse(try AdvanziaLocalSecrets.hasPassword(a, using: client))
        XCTAssertEqual(try AdvanziaLocalSecrets.read(b, using: client), "invented-b")
    }
    func testKeychainFailuresAreNotMistakenForMissingCredentials() {
        let fake = FakeAdvanziaKeychain()
        fake.forcedError = errSecAuthFailed
        XCTAssertThrowsError(try AdvanziaLocalSecrets.hasPassword("fictional", using: fake.client))
        XCTAssertThrowsError(try AdvanziaLocalSecrets.read("fictional", using: fake.client))
    }
    func testConnectionEditorPersistsPasswordAndAppPreference() async throws {
        let pin = try XCTUnwrap(model.pinVault())
        let id = try await pin.run { try $0.addBankConnection(connector: .advanzia, displayName: "Testkarte", loginName: "demo") }
        let connections = try await pin.run { try $0.listBankConnections() }
        let connection = try XCTUnwrap(connections.first { $0.id == id })
        let fake = FakeAdvanziaKeychain()
        let editor = AdvanziaConnectionSettingsState(keychain: fake.client)
        await editor.load(connectionID: id, model: model)
        editor.storePassword = true; editor.password = "invented-password"; editor.authMethod = .app
        let saved = await editor.save(connection: connection, name: "Testkarte", login: "demo", model: model)
        XCTAssertNotNil(saved); XCTAssertNil(editor.error); XCTAssertTrue(editor.hasSavedPassword)
        let profile = try await pin.run { try $0.advanziaProfile(connectionId: id) }
        XCTAssertEqual(profile.authMethod, "app")
        XCTAssertEqual(try AdvanziaLocalSecrets.read(profile.profileId, using: fake.client), "invented-password")
        let reopened = AdvanziaConnectionSettingsState(keychain: fake.client)
        await reopened.load(connectionID: id, model: model)
        XCTAssertTrue(reopened.storePassword); XCTAssertEqual(reopened.authMethod, .app); XCTAssertEqual(reopened.password, "")
        await reopened.removePassword(model: model)
        XCTAssertFalse(try AdvanziaLocalSecrets.hasPassword(profile.profileId, using: fake.client))
    }
}
