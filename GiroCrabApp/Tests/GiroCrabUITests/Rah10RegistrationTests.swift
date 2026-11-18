import XCTest
import GiroCrabCore
@testable import GiroCrabUI

@MainActor
final class Rah10RegistrationTests: XCTestCase {
    func testBankKeyRequestWaitsForRegistrationSave() async throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        let vault = try XCTUnwrap(model.vault)
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        model.settingsWriteTask = Task { for await _ in gate {} }
        model.saveSettingInBackground("fints.product_id", "OWN-TEST-ID")

        let started = expectation(description: "request started")
        var prepared = false
        let request = Task { @MainActor in
            started.fulfill()
            let pin = try await model.prepareRah10BankKeyRequest()
            prepared = true
            return pin
        }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertFalse(prepared, "The request must wait for the queued registration write")
        XCTAssertNil(try vault.getSetting(key: "fints.product_id"))

        release.finish()
        let pin = try await request.value
        let source = try await pin.run { try $0.fintsProductIdSource() }
        XCTAssertEqual(source, "own")
        XCTAssertEqual(try vault.getSetting(key: "fints.product_id"), "OWN-TEST-ID")
    }

    func testWaitingRequestDoesNotFollowVaultSwitch() async throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        model.settingsWriteTask = Task { for await _ in gate {} }
        let started = expectation(description: "request started")
        let request = Task { @MainActor in
            started.fulfill()
            return try await model.prepareRah10BankKeyRequest()
        }
        await fulfillment(of: [started], timeout: 1)
        // Demo mode deliberately ignores lock(); close its active vault directly.
        model.releaseVaultState()
        release.finish()
        do {
            _ = try await request.value
            XCTFail("A request for the old vault must be cancelled")
        } catch CoreError.SessionClosed {
            // No request may continue against another or a locked vault.
        }
    }
}
