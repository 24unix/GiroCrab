import XCTest
import Security
import GiroCrabCore
@testable import GiroCrabUI

@MainActor
final class AdvanziaAddTests: XCTestCase {
    private var model: AppModel!
    private var pin: VaultPin!
    private var fake: FakeAdvanziaKeychain!
    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        await model.merchantStatsTask?.value
        pin = try XCTUnwrap(model.pinVault())
        fake = FakeAdvanziaKeychain()
    }
    override func tearDown() async throws { model = nil; pin = nil; fake = nil }
    private func draft() -> AdvanziaAddState {
        let state = AdvanziaAddState(keychain: fake.client)
        state.login = "demo"; state.password = "fictional-password"; state.method = .app
        return state
    }
    func testNewConnectionSavesPasswordAndMethodBeforeAnyFetchStarts() async throws {
        let state = draft()
        let saved = await state.save(pin: pin, model: model)
        let connection = try XCTUnwrap(saved)
        let profile = try await pin.run { try $0.advanziaProfile(connectionId: connection.id) }
        XCTAssertEqual(profile.authMethod, "app")
        XCTAssertEqual(try AdvanziaLocalSecrets.read(profile.profileId, using: fake.client), "fictional-password")
        XCTAssertEqual(state.password, ""); XCTAssertNil(state.error)
        XCTAssertNil(model.advanziaWorkflow); XCTAssertNil(model.webLoginConnection)
        XCTAssertTrue(model.connections.contains { $0.id == connection.id })
    }
    func testRepeatedSetupUpdatesOneConnectionAndCanDisablePasswordStorage() async throws {
        let first = draft()
        let saved = await first.save(pin: pin, model: model)
        let connection = try XCTUnwrap(saved)
        let second = draft(); second.storePassword = false; second.method = .sms
        let updated = await second.save(pin: pin, model: model)
        XCTAssertEqual(updated?.id, connection.id)
        let profile = try await pin.run { try $0.advanziaProfile(connectionId: connection.id) }
        XCTAssertEqual(profile.authMethod, "sms")
        XCTAssertFalse(try AdvanziaLocalSecrets.hasPassword(profile.profileId, using: fake.client))
        let connections = try await pin.run { try $0.listBankConnections() }
        XCTAssertEqual(connections.filter { $0.connector == .advanzia && $0.loginName == "demo" }.count, 1)
        XCTAssertNil(model.advanziaWorkflow)
    }
    func testKeychainFailureKeepsSetupOpenAndRetryDoesNotDuplicateTheLogin() async throws {
        let state = draft(); fake.forcedError = errSecAuthFailed
        let failed = await state.save(pin: pin, model: model)
        XCTAssertNil(failed); XCTAssertNotNil(state.error); XCTAssertFalse(state.busy)
        XCTAssertEqual(state.password, "fictional-password"); XCTAssertNil(model.advanziaWorkflow)
        fake.forcedError = nil
        let saved = await state.save(pin: pin, model: model)
        XCTAssertNotNil(saved); XCTAssertNil(state.error)
        let connections = try await pin.run { try $0.listBankConnections() }
        XCTAssertEqual(connections.filter { $0.connector == .advanzia && $0.loginName == "demo" }.count, 1)
    }
    func testIncompleteInputDoesNotAddAConnection() async throws {
        let state = AdvanziaAddState(keychain: fake.client)
        state.login = "demo"
        XCTAssertFalse(state.canAdd)
        let saved = await state.save(pin: pin, model: model)
        XCTAssertNil(saved)
        let connections = try await pin.run { try $0.listBankConnections() }
        XCTAssertFalse(connections.contains { $0.connector == .advanzia })
    }
    func testCancelClearsTheEnteredPassword() {
        let state = draft(); state.cancel()
        XCTAssertEqual(state.password, ""); XCTAssertFalse(state.busy)
        XCTAssertFalse(state.canAdd)
    }
}
