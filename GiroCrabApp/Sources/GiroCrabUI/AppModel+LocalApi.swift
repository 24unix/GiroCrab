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
        if let path = localApiSocketPathOverride { return path }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("GiroCrab/local-api/girocrab.sock").path
    }

    /// Tests: a short path outside Application Support (`sun_path` holds 104 bytes).
    nonisolated(unsafe) static var localApiSocketPathOverride: String?

    var isLocalApiRunning: Bool { localApiServer != nil }

    /// The one rule, checked whenever `ownVault` or `demoActive` changes: a
    /// server runs only for the own vault while it is shown, and only for the
    /// vault it was started on. Starting is `refreshLocalApiServer`'s job.
    func enforceLocalApiServerVault() {
        if holdsRealData {
            if localApiServer != nil, localApiServerVault !== ownVault { stopLocalApiServer() }
        } else if localApiServer != nil || localApiStartError != nil {
            stopLocalApiServer()
        }
    }

    /// Starts or stops the socket to match the stored settings. Called when a vault
    /// opens (`useVault`), after every settings change and, after a failed start,
    /// when the app becomes active again.
    /// Only the newest refresh acts: an older one may have read the scope before
    /// a later save turned access off.
    func refreshLocalApiServer() {
        #if os(macOS)
        localApiRefreshGeneration &+= 1
        let generation = localApiRefreshGeneration
        guard holdsRealData, let v = ownVault else { stopLocalApiServer(); return }
        Task {
            let read: Result<ShareScope, Error>
            do { read = .success(try await Self.offMain { try v.localApiScope() }) } catch { read = .failure(error) }
            // Locked, swapped, switched to the demo or a newer refresh meanwhile.
            guard generation == self.localApiRefreshGeneration,
                  self.holdsRealData, self.ownVault === v else { return }
            let scope: ShareScope
            switch read {
            case .success(let s): scope = s
            case .failure(let error):
                self.stopLocalApiServer()
                self.localApiStartError = describe(error)
                return
            }
            guard scope.enabled, !scope.tokenSha256.isEmpty else {
                self.stopLocalApiServer()
                return
            }
            if self.localApiServer != nil {
                if self.localApiServerVault === v { return }
                self.stopLocalApiServer()
            }
            _ = Self.localApiQuitObserver
            _ = Self.localApiActivationObserver
            Self.localApiRetryTarget = self
            do {
                let server = try LocalApiServer.start(vault: v, socketPath: Self.localApiSocketPath)
                self.localApiServer = server
                self.localApiServerVault = v
                Self.runningLocalApiServer = server
                self.localApiStartError = nil
            } catch {
                // Kept for the status line: a toast alone would leave "starting" forever.
                // The core words its start errors for the user (localized).
                if case .InvalidInput(let message)? = error as? CoreError {
                    self.localApiStartError = message
                } else {
                    self.localApiStartError = describe(error)
                }
            }
        }
        #endif
    }

    /// After a failed start (e.g. another instance served the socket): try again.
    func retryLocalApiStart() {
        if localApiStartError != nil { refreshLocalApiServer() }
    }

    #if os(macOS)
    /// The server this process runs, for the quit observer (no model there).
    @MainActor static weak var runningLocalApiServer: LocalApiServer?

    /// The model whose start the activation observer retries.
    @MainActor static weak var localApiRetryTarget: AppModel?

    /// Coming back to the app (the other instance may have quit meanwhile).
    static let localApiActivationObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { _ in
        MainActor.assumeIsolated { AppModel.localApiRetryTarget?.retryLocalApiStart() }
    }

    /// Quit: nothing else stops the server on exit. `stop()` removes only the
    /// socket file this server created and returns at once.
    static let localApiQuitObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { _ in
        MainActor.assumeIsolated { AppModel.runningLocalApiServer?.stop() }
    }
    #endif

    /// Closes the socket and removes its file (lock, demo, settings turned off).
    /// Returns at once: the core's `stop()` does not wait for its threads.
    func stopLocalApiServer() {
        localApiServer?.stop()
        localApiServer = nil
        localApiServerVault = nil
        localApiStartError = nil
    }

    /// Every settings call of this feature, one after another on the own vault
    /// as it was when the call was made: a read never overtakes a pending save,
    /// quick toggles keep the newest, and nothing lands in the demo vault. nil
    /// when the own vault is not shown or was locked before the call's turn; a
    /// call that ran returns its result even if the vault was swapped since
    /// (a committed token is still shown).
    private func localApiCall<T: Sendable>(_ work: @escaping @Sendable (Vault) throws -> T) async throws -> T? {
        guard holdsRealData, let v = ownVault else { return nil }
        let previous = localApiQueue
        let job = Task { () -> Result<T, Error>? in
            await previous?.value
            guard self.ownVault === v else { return nil }
            do { return .success(try await Self.offMain { try work(v) }) } catch { return .failure(error) }
        }
        localApiQueue = Task { _ = await job.value }
        return try await job.value?.get()
    }

    func loadLocalApiScope() async -> ShareScope? {
        try? await localApiCall { try $0.localApiScope() }
    }

    /// Saves what is shared (the token stays) and starts or stops the socket.
    /// false when nothing was written (failed, or the own vault went away first).
    @discardableResult
    func saveLocalApiScope(_ scope: ShareScope) async -> Bool {
        defer { refreshLocalApiServer() }
        do {
            return try await localApiCall { try $0.setLocalApiScope(scope: scope) } != nil
        } catch {
            errorMessage = describe(error)
            return false
        }
    }

    /// A new access token, shown once; the previous one stops working.
    func createLocalApiToken() async -> String? {
        defer { refreshLocalApiServer() }
        do {
            return try await localApiCall { try $0.createLocalApiToken() }
        } catch {
            errorMessage = describe(error)
            return nil
        }
    }

    func revokeLocalApiToken() async {
        do {
            _ = try await localApiCall { try $0.revokeLocalApiToken() }
        } catch {
            errorMessage = describe(error)
        }
        refreshLocalApiServer()
    }
}
