import Foundation
import GiroCrabCore

extension AppModel {
    func usesRah10(_ connection: BankConnection) -> Bool {
        connectionKey(connection).hasSuffix(":rah10")
    }

    func inspectRah10File(bytes: Data, password: String) async throws -> Rah10KeyfileInfo {
        try await Self.offMain { try inspectRah10Keyfile(bytes: bytes, password: password) }
    }

    func fetchRah10BankKeys(blz: String) async throws -> [Rah10BankKeyCandidate] {
        let pin = try await prepareRah10BankKeyRequest()
        await withCheckedContinuation { continuation in
            withFreshBankingPolicy { continuation.resume() }
        }
        guard isCurrent(pin) else { throw CoreError.SessionClosed }
        let keys = try await pin.runAsync { try await $0.rah10BankKeyCandidates(blz: blz) }
        guard isCurrent(pin) else { throw CoreError.SessionClosed }
        return keys
    }

    /// The registration field saves off the main thread. Do not start the first
    /// bank request until that write has finished, or move it to a different vault.
    func prepareRah10BankKeyRequest() async throws -> VaultPin {
        guard let pin = pinVault() else { throw CoreError.Database(message: "vault locked") }
        await settingsWriteTask?.value
        guard isCurrent(pin) else { throw CoreError.SessionClosed }
        return pin
    }

    func addRah10Connection(bytes: Data, password: String, name: String, bankKeys: [Rah10BankKeyCandidate], expected: [String], completion: @escaping (Bool) -> Void) {
        withFreshBankingPolicy { [self] in
            guard bankingAllowsAdding(bankingGate(forNew: .finTsGeneric)) else { completion(false); return }
            if demoActive, let ov = ownVault { useVault(ov, demo: false) }
            guard let pin = pinVault() else { completion(false); return }
            Task {
                do {
                    let id = try await pin.run {
                        try $0.addRah10ConnectionWithBankKeys(bytes: bytes, password: password, displayName: name, bankKeys: bankKeys, expectedFingerprints: expected)
                    }
                    // A committed import stays successful if the vault was swapped.
                    guard isCurrent(pin) else { completion(true); return }
                    reloadSettings()
                    reloadAccounts()
                    completion(true)
                    if let connection = connections.first(where: { $0.id == id }) {
                        startSync(connection, secret: password)
                    }
                } catch {
                    if isCurrent(pin) { errorMessage = describe(error) }
                    completion(false)
                }
            }
        }
    }
}
