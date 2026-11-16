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

    /// Starts or stops the socket to match the stored settings. Called when a vault
    /// opens (`useVault`) and after every settings change.
    func refreshLocalApiServer() {
        #if os(macOS)
        guard holdsRealData, let v = ownVault else { stopLocalApiServer(); return }
        Task {
            let scope = try? await Self.offMain { try v.localApiScope() }
            // Locked, swapped or switched to the demo meanwhile: nothing to start.
            guard self.holdsRealData, self.ownVault === v else { return }
            guard let scope, scope.enabled, !scope.tokenSha256.isEmpty else {
                self.stopLocalApiServer()
                return
            }
            guard self.localApiServer == nil else { return }
            _ = Self.localApiQuitObserver
            do {
                let server = try LocalApiServer.start(vault: v, socketPath: Self.localApiSocketPath)
                self.localApiServer = server
                Self.runningLocalApiServer = server
                self.localApiStartError = nil
            } catch {
                // Kept for the status line: a toast alone would leave "starting" forever.
                self.localApiStartError = describe(error)
            }
        }
        #endif
    }

    #if os(macOS)
    /// The server this process runs, for the quit observer (no model there).
    @MainActor static weak var runningLocalApiServer: LocalApiServer?

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
        localApiStartError = nil
    }

    func loadLocalApiScope() async -> ShareScope? {
        guard holdsRealData else { return nil }
        return try? await vaultOffMain { try $0.localApiScope() }
    }

    /// Saves what is shared (the token stays) and starts or stops the socket.
    /// Saves run in order: quick toggles must not let an older copy win.
    func saveLocalApiScope(_ scope: ShareScope) async {
        guard holdsRealData else { return }
        let previous = localApiSaveTask
        let save = Task {
            await previous?.value
            do {
                _ = try await self.vaultOffMain { try $0.setLocalApiScope(scope: scope) }
            } catch {
                self.errorMessage = describe(error)
            }
        }
        localApiSaveTask = save
        await save.value
        refreshLocalApiServer()
    }

    /// A new access token, shown once; the previous one stops working.
    func createLocalApiToken() async -> String? {
        guard holdsRealData else { return nil }
        do {
            let token = try await vaultOffMain { try $0.createLocalApiToken() }
            refreshLocalApiServer()
            return token
        } catch {
            errorMessage = describe(error)
            return nil
        }
    }

    func revokeLocalApiToken() async {
        guard holdsRealData else { return }
        do {
            _ = try await vaultOffMain { try $0.revokeLocalApiToken() }
        } catch {
            errorMessage = describe(error)
        }
        refreshLocalApiServer()
    }
}
