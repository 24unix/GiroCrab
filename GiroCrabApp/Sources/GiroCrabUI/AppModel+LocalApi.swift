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

    #if os(macOS)
    /// The MCP adapter for AI assistants (`girocrab-mcp`): in the app at
    /// `Contents/Helpers/girocrab-mcp`, in a developer build the repository's
    /// newer of `target/release` and `target/debug` (looked up each time, so a
    /// helper built while the app runs is found). nil = not built. macOS only:
    /// on iOS no other app could reach the socket.
    nonisolated static var localApiHelperURL: URL? {
        if let bundledLocalApiHelper { return bundledLocalApiHelper }
        #if DEBUG
        return localApiDevelopmentHelper()
        #else
        return nil
        #endif
    }

    nonisolated private static let bundledLocalApiHelper: URL? = {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/girocrab-mcp")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }()

    #if DEBUG
    /// The helper built in this source tree (also for the tests, whose runner
    /// is no app bundle): this file is GiroCrabApp/Sources/GiroCrabUI/….
    nonisolated static func localApiDevelopmentHelper(sourceFile: String = #filePath) -> URL? {
        let fm = FileManager.default
        var root = URL(fileURLWithPath: sourceFile)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let modified = { (url: URL) in
            (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
        }
        return ["release", "debug"]
            .map { root.appendingPathComponent("target/\($0)/girocrab-mcp") }
            .filter { fm.isExecutableFile(atPath: $0.path) }
            .max { modified($0) < modified($1) }
    }
    #endif

    /// `helper` runs from a temporary copy (Gatekeeper's App Translocation when
    /// the app was opened from Downloads): its path vanishes after a restart.
    nonisolated static func localApiHelperIsTemporary(_ helper: URL) -> Bool {
        helper.path.contains("/AppTranslocation/")
    }

    /// The entry for an MCP client's configuration (the common `mcpServers`
    /// form), with the helper's path and `token` (or a placeholder).
    nonisolated static func localApiClientConfig(helper: URL, token: String?) -> String {
        func quoted(_ s: String) -> String {
            let data = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        }
        return """
        {
          "mcpServers": {
            "girocrab": {
              "command": \(quoted(helper.path)),
              "env": { "GIROCRAB_API_TOKEN": \(quoted(token ?? "gcapi_…")) }
            }
          }
        }
        """
    }

    /// Runs `helper --check --json` the way an MCP client starts it: on the
    /// helper's default socket path (the app's own only when tests moved it), with
    /// the key just created if it is still shown, otherwise without one (then
    /// only reachability is known). Cancelling the task ends the helper.
    func checkLocalApiConnection(helper: URL) async -> LocalApiCheck {
        let socket = Self.localApiSocketPathOverride
        guard let output = await Self.runHelperCheck(helper, socket: socket, token: localApiNewToken) else {
            return .noAnswer
        }
        // `--check --json` prints {"problem": …, "message": …} on stdout (girocrab-mcp,
        // Problem::name); stderr carries warnings, or the error of an older helper.
        let answer = (try? JSONSerialization.jsonObject(with: Data(output.stdout.utf8))) as? [String: Any]
        let firstLine = { (text: String) in text.split(separator: "\n").first.map(String.init) }
        let message = answer?["message"] as? String
            ?? firstLine(output.stderr) ?? firstLine(output.stdout) ?? ""
        switch answer?["problem"] as? String {
        case "ok": return .works
        case "unreachable": return .notReachable
        case "no_key": return .reachableWithoutKey
        case "key_rejected": return .keyRejected
        case "disabled": return .turnedOff
        case "locked": return .locked
        case "busy": return .busy
        default: return .failed(message)
        }
    }

    /// Longer than the helper's own worst case (30 s for one answer, then a few
    /// short retries), so its own message arrives rather than a kill.
    nonisolated private static let helperCheckLimit: TimeInterval = 45

    /// Output of `girocrab-mcp --check --json`; nil when it had to be stopped
    /// (time limit or the calling task was cancelled).
    nonisolated private static func runHelperCheck(
        _ helper: URL, socket: String?, token: String?
    ) async -> (stdout: String, stderr: String)? {
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--check", "--json"]
        var env = ProcessInfo.processInfo.environment
        env["GIROCRAB_API_SOCKET"] = socket
        env["GIROCRAB_API_TOKEN"] = token
        process.environment = env
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { p in
                    let read = { (pipe: Pipe) in
                        String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    }
                    let output = (stdout: read(stdout), stderr: read(stderr))
                    continuation.resume(returning: p.terminationReason == .exit ? output : nil)
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (stdout: "", stderr: error.localizedDescription))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + helperCheckLimit) {
                    if process.isRunning { process.terminate() }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
    #endif

    /// Tests: a short path outside Application Support (`sun_path` holds 104 bytes).
    nonisolated(unsafe) static var localApiSocketPathOverride: String?

    var isLocalApiRunning: Bool { localApi != nil }

    /// The vault the socket may serve: the own one, unlocked and shown (not the
    /// demo, not behind the lock screen while the unlock still loads). nil =
    /// nothing. The one definition every start, stop and settings call checks.
    private var localApiTarget: Vault? {
        holdsRealData && vaultState == .open ? ownVault : nil
    }

    /// Matches the socket to `localApiTarget` and its stored settings. Runs
    /// whenever `ownVault`, `demoActive` or `vaultState` changes (every path that
    /// locks, unlocks, swaps or shows the demo) and after a failed start on activation.
    /// Stopping is immediate; starting follows the queued scope read. macOS only:
    /// on iOS no other app could reach the socket, so nothing runs there.
    func reconcileLocalApiServer() {
        #if os(macOS)
        let target = localApiTarget
        if target == nil || localApi?.servedVault !== target { stopLocalApiServer() }
        guard target != nil else {
            // Locked, demo or unlocking: a key shown once is never shown again.
            if localApiScope != nil { localApiScope = nil }
            if localApiNewToken != nil { localApiNewToken = nil }
            return
        }
        Task { _ = try? await localApiJob { _ in () } }
        #endif
    }

    /// After a failed start (e.g. another instance served the socket): try again.
    func retryLocalApiStart() {
        if localApiStartError != nil { reconcileLocalApiServer() }
    }

    /// Closes the socket and removes its file (also on quit), and clears a start
    /// error. Returns at once: the core's `stop()` does not wait for its threads.
    func stopLocalApiServer() {
        guard localApi != nil || localApiStartError != nil else { return }
        localApi?.server.stop()
        localApi = nil
        localApiStartError = nil
    }

    /// Every call of this feature, one after another on the target vault as it
    /// was when the call was made: a read never overtakes a pending save, quick
    /// toggles keep the newest, and nothing lands in the demo vault. A queued
    /// call still runs while that vault stays unlocked (a save made just before
    /// the demo was shown is kept). The same background hop reads the stored
    /// scope afterwards, and the job ends by matching the socket and
    /// `localApiScope` to it, so the queue also orders starts and stops. nil when
    /// there is no target, or the vault was locked or swapped before the call's
    /// turn; a call that ran returns its result even if the target changed since.
    /// `publish` runs in the job, after the socket was matched, only while the
    /// target is unchanged (so no later job can overtake it).
    private func localApiJob<T: Sendable>(
        _ work: @escaping @Sendable (Vault) throws -> T,
        publish: ((T) -> Void)? = nil
    ) async throws -> T? {
        guard let v = localApiTarget else { return nil }
        let previous = localApiQueue
        localApiJobs &+= 1
        let number = localApiJobs
        let job = Task { () -> Result<T, Error>? in
            await previous?.value
            guard self.ownVault === v else { return nil }
            // offMain throws only when cancelled.
            guard let (result, stored) = try? await Self.offMain({
                (Result { try work(v) }, Result { try v.localApiScope() })
            }) else { return nil }
            self.applyLocalApiScope(stored, for: v, isNewest: number == self.localApiJobs)
            if case .success(let value) = result, self.localApiTarget === v {
                publish?(value)
            }
            return result
        }
        localApiQueue = Task { _ = await job.value }
        return try await job.value?.get()
    }

    /// The end of every job: publish the stored scope and start, keep or stop
    /// the socket for `v`. While newer jobs wait, only the token is taken over,
    /// so quick toggles do not flicker back; the newest job publishes it all
    /// (and so undoes a save that failed).
    private func applyLocalApiScope(_ stored: Result<ShareScope, Error>, for v: Vault, isNewest: Bool) {
        // The target changed meanwhile: the didSet already stopped the socket.
        guard localApiTarget === v else { return }
        let scope: ShareScope
        switch stored {
        case .success(let s): scope = s
        case .failure(let error):
            stopLocalApiServer()
            localApiStartError = describe(error)
            return
        }
        // Another token (revoked, replaced): the one shown is no longer valid.
        if scope.tokenSha256 != (localApiScope?.tokenSha256 ?? "") { localApiNewToken = nil }
        if isNewest || localApiScope == nil {
            localApiScope = scope
        } else {
            localApiScope?.tokenSha256 = scope.tokenSha256
        }
        guard scope.enabled, !scope.tokenSha256.isEmpty else {
            stopLocalApiServer()
            return
        }
        #if os(macOS)
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
    /// (failed, or the own vault went away first); the job then restores
    /// `localApiScope` to what is stored.
    @discardableResult
    func saveLocalApiScope(_ scope: ShareScope) async -> Bool {
        if localApiTarget != nil { localApiScope = shownScope(scope) }
        return await localApiWrite { try $0.setLocalApiScope(scope: scope) } != nil
    }

    /// A switch in the settings pane: shown at once, saved in the queue.
    func updateLocalApiScope(_ scope: ShareScope) {
        guard localApiTarget != nil else { return }
        localApiScope = shownScope(scope)
        Task { await saveLocalApiScope(scope) }
    }

    /// What the pane shows for `scope` before the core answers: switching external
    /// access off revokes the key in the core, so the pane no longer offers one.
    private func shownScope(_ scope: ShareScope) -> ShareScope {
        guard localApiScope?.enabled == true, !scope.enabled else { return scope }
        var shown = scope
        shown.tokenSha256 = ""
        localApiNewToken = nil
        return shown
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
