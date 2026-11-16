import Foundation
import GiroCrabCore
#if os(macOS)
import AppKit
#endif

// Read-only local interface for external analysis (GitHub #136): the socket
// (`LocalApiServer` in the core) runs only while the personal vault is unlocked
// and shown, never for the demo, and only when the user enabled it and created
// an access token. Settings UI: ExternalAccessSettings.swift.

extension AppModel {
    /// `~/Library/Application Support/GiroCrab/local-api/girocrab.sock` (the core
    /// creates the folder with mode 0700, the socket with 0600).
    nonisolated static var localApiSocketPath: String {
        localApiSocketPathOverride ?? defaultLocalApiSocketPath
    }

    nonisolated private static let defaultLocalApiSocketPath: String = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("GiroCrab/local-api/girocrab.sock").path
    }()

    /// Tests: a short path outside Application Support (`sun_path` holds 104 bytes).
    nonisolated(unsafe) static var localApiSocketPathOverride: String?

    var isLocalApiRunning: Bool { localApi != nil }

    /// The own vault is unlocked and shown: not the demo, not the lock screen
    /// (also not while the unlock still loads behind it).
    private var mayServeLocalApi: Bool { holdsRealData && vaultState == .open }

    /// Matches the socket to the current vault and its stored settings. Runs
    /// whenever `ownVault`, `demoActive` or `vaultState` changes (every path that
    /// locks, unlocks, swaps or shows the demo) and after a failed start on activation.
    /// Stopping is immediate; starting follows the queued scope read. macOS only:
    /// on iOS no other app could reach the socket, so nothing runs there.
    func reconcileLocalApiServer() {
        #if os(macOS)
        guard holdsRealData else {
            if localApi != nil || localApiStartError != nil { stopLocalApiServer() }
            // Locked or demo: a key shown once is never shown again.
            localApiTokenHash = ""
            localApiNewToken = nil
            return
        }
        if let running = localApi, running.servedVault !== ownVault { stopLocalApiServer() }
        // Lock screen still up (unlocking): `.open` comes back here.
        guard vaultState == .open else {
            if localApi != nil { stopLocalApiServer() }
            return
        }
        Task { _ = try? await localApiJob { _ in () } }
        #endif
    }

    /// After a failed start (e.g. another instance served the socket): try again.
    func retryLocalApiStart() {
        if localApiStartError != nil { reconcileLocalApiServer() }
    }

    /// Closes the socket and removes its file (also on quit). Returns at once:
    /// the core's `stop()` does not wait for its threads.
    func stopLocalApiServer() {
        localApi?.server.stop()
        localApi = nil
        localApiStartError = nil
    }

    /// Every call of this feature, one after another on the own vault as it was
    /// when the call was made: a read never overtakes a pending save, quick
    /// toggles keep the newest, and nothing lands in the demo vault. The same
    /// background hop reads the stored scope afterwards, and the job ends by
    /// matching the socket to it, so the queue also orders starts and stops.
    /// nil when the own vault is not shown or was locked before the call's turn;
    /// a call that ran returns its result even if the vault was swapped since.
    /// `publish` runs in the job, after the socket was matched, only while the
    /// vault is still the own, shown one (so no later job can overtake it).
    private func localApiJob<T: Sendable>(
        _ work: @escaping @Sendable (Vault) throws -> T,
        publish: ((T) -> Void)? = nil
    ) async throws -> T? {
        guard holdsRealData, let v = ownVault else { return nil }
        let previous = localApiQueue
        let job = Task { () -> Result<T, Error>? in
            await previous?.value
            guard self.ownVault === v else { return nil }
            // offMain throws only when cancelled.
            guard let (result, stored) = try? await Self.offMain({
                (Result { try work(v) }, Result { try v.localApiScope() })
            }) else { return nil }
            self.applyLocalApiScope(stored, for: v)
            if case .success(let value) = result, self.holdsRealData, self.ownVault === v {
                publish?(value)
            }
            return result
        }
        localApiQueue = Task { _ = await job.value }
        return try await job.value?.get()
    }

    /// The end of every job: start, keep or stop the socket for `v`.
    private func applyLocalApiScope(_ stored: Result<ShareScope, Error>, for v: Vault) {
        // Locked, swapped or switched to the demo meanwhile: the didSet already stopped it.
        guard holdsRealData, ownVault === v else { return }
        let scope: ShareScope
        switch stored {
        case .success(let s): scope = s
        case .failure(let error):
            stopLocalApiServer()
            localApiStartError = describe(error)
            return
        }
        // Another token (revoked, replaced): the one shown is no longer valid.
        if scope.tokenSha256 != localApiTokenHash { localApiNewToken = nil }
        localApiTokenHash = scope.tokenSha256
        guard scope.enabled, !scope.tokenSha256.isEmpty else {
            if localApi != nil || localApiStartError != nil { stopLocalApiServer() }
            return
        }
        #if os(macOS)
        guard mayServeLocalApi else { return }
        if localApi?.servedVault === v { return }
        stopLocalApiServer()
        _ = Self.localApiActivationObserver
        _ = Self.localApiQuitObserver
        Self.localApiOwner = self
        do {
            let server = try LocalApiServer.start(vault: v, socketPath: Self.localApiSocketPath)
            localApi = RunningLocalApi(server: server, servedVault: v)
        } catch {
            // Kept for the status line: a toast alone would leave "starting" forever.
            // The core words its start errors for the user (localized).
            if case .InvalidInput(let message)? = error as? CoreError {
                localApiStartError = message
            } else {
                localApiStartError = describe(error)
            }
        }
        #endif
    }

    #if os(macOS)
    /// The model whose socket the app observers below act on.
    @MainActor static weak var localApiOwner: AppModel?

    /// Quit: ends the threads and removes the socket file right away (a file left
    /// behind by a crash is replaced on the next start, see the core's lock file).
    static let localApiQuitObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { _ in
        MainActor.assumeIsolated { AppModel.localApiOwner?.stopLocalApiServer() }
    }

    /// Coming back to the app (the other instance may have quit meanwhile).
    static let localApiActivationObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { _ in
        MainActor.assumeIsolated { AppModel.localApiOwner?.retryLocalApiStart() }
    }
    #endif

    /// A job whose error goes to `errorMessage`.
    private func localApiWrite<T: Sendable>(
        _ work: @escaping @Sendable (Vault) throws -> T,
        publish: ((T) -> Void)? = nil
    ) async -> T? {
        do {
            return try await localApiJob(work, publish: publish)
        } catch {
            errorMessage = describe(error)
            return nil
        }
    }

    func loadLocalApiScope() async -> ShareScope? {
        try? await localApiJob { try $0.localApiScope() }
    }

    /// Saves what is shared (the token stays). false when nothing was written
    /// (failed, or the own vault went away first).
    @discardableResult
    func saveLocalApiScope(_ scope: ShareScope) async -> Bool {
        await localApiWrite { try $0.setLocalApiScope(scope: scope) } != nil
    }

    /// A new access token, shown once (`localApiNewToken`); the previous one stops working.
    @discardableResult
    func createLocalApiToken() async -> String? {
        await localApiWrite({ try $0.createLocalApiToken() }, publish: { self.localApiNewToken = $0 })
    }

    /// The pane closed: the new key is not shown again.
    func forgetNewLocalApiToken() {
        localApiNewToken = nil
    }

    func revokeLocalApiToken() async {
        _ = await localApiWrite { try $0.revokeLocalApiToken() }
    }
}
