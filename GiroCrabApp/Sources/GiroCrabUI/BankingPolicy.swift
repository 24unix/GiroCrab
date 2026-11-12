import CryptoKit
import Foundation
import Observation
import Security
import GiroCrabCore

// MARK: - Security lock for bank connections ("Sicherheitssperre")
//
// The publisher can publish a signed `banking-policy.json` with a minimum
// version per distribution (Developer ID, Mac App Store, iOS) and channel.
// An older build may then no longer contact banks: no syncs, no transfers, no
// new or changed bank logins. Reading, searching, exporting stay possible.
// The file can only *restrict* existing functions; it never unlocks or adds
// anything and contains no code (App Review Guideline 2.5.2 / 2.4.5 (iv)).
//
// See docs/banking-policy.md for the file format, the release tooling and the
// emergency procedure.

/// Where this build comes from. Set via the Info.plist key `GiroCrabDistribution`.
public enum BankingDistribution: String, Sendable, CaseIterable {
    case developerID = "developer-id"
    case macAppStore = "mac-app-store"
    case iOS = "ios"

    public static var current: BankingDistribution {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "GiroCrabDistribution") as? String,
           let d = BankingDistribution(rawValue: raw) {
            return d
        }
        #if os(macOS)
        return .developerID
        #else
        return .iOS
        #endif
    }
}

// MARK: - File format (schema 1)

public struct BankingPolicyDocument: Equatable, Sendable {
    public struct Rule: Equatable, Sendable {
        /// Known distributions of this rule (unknown values are ignored).
        public var distributions: Set<BankingDistribution>
        /// nil = all channels; otherwise the known channels of this rule.
        public var channels: Set<AppUpdateChannel>?
        public var minimumVersion: String
        /// nil = all connectors; otherwise connector IDs (prefix rule, see `BankingPolicy.connectorID(_:matches:)`).
        public var connectors: [String]?
        public var advisory: URL?
        public var updateAvailable: Bool
    }

    public static let supportedSchema = 1

    public var schema: Int
    public var issued: String?
    public var sequence: UInt64
    public var rules: [Rule]

    private struct Raw: Decodable {
        struct RawRule: Decodable {
            var distribution: [String]
            var channels: [String]?
            var minimumVersion: String
            var connectors: [String]?
            var advisory: String?
            var updateAvailable: Bool?
        }
        var schema: Int
        var issued: String?
        var sequence: UInt64
        var rules: [RawRule]
    }

    public enum ParseError: Error, Equatable {
        case malformed
        case unknownSchema(Int)
    }

    /// Parses the exact bytes that were signed. Unknown values in
    /// `distribution`/`channels` are ignored (a newer publisher may know more
    /// distributions); a rule with no known distribution left applies nowhere.
    public static func parse(_ data: Data) throws -> BankingPolicyDocument {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { throw ParseError.malformed }
        guard raw.schema == supportedSchema else { throw ParseError.unknownSchema(raw.schema) }
        let rules = raw.rules.map { r in
            Rule(
                distributions: Set(r.distribution.compactMap(BankingDistribution.init(rawValue:))),
                channels: r.channels.map { Set($0.compactMap(AppUpdateChannel.init(rawValue:))) },
                minimumVersion: r.minimumVersion.trimmingCharacters(in: .whitespaces),
                connectors: r.connectors?.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                advisory: r.advisory.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil },
                updateAvailable: r.updateAvailable ?? true
            )
        }
        return BankingPolicyDocument(schema: raw.schema, issued: raw.issued, sequence: raw.sequence, rules: rules)
    }
}

// MARK: - Result for this build

/// Why bank contact is not allowed.
public struct BankingGate: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// This version is older than the policy's minimum version.
        case outdated
        /// No policy was ever verified online on this device and the check failed now.
        case checkUnavailable
    }

    public var reason: Reason
    /// True if every connector is blocked; else `connectorIDs` lists the blocked ones.
    public var all: Bool
    public var connectorIDs: [String]
    public var minimumVersion: String?
    public var advisory: URL?
    public var updateAvailable: Bool

    /// Human-readable message for banner, help texts and core errors.
    public var message: String {
        switch reason {
        case .checkUnavailable:
            return String(localized: "Sicherheitsprüfung nicht möglich. GiroCrab konnte nicht prüfen, ob diese Version noch sicher mit Banken kommunizieren darf. Bitte später erneut versuchen.")
        case .outdated:
            var text: String
            if all {
                text = String(localized: "Bankverbindungen sind gesperrt, weil diese Version eine Sicherheitslücke oder einen schweren Fehler im Bankzugang enthält. Ihre Daten bleiben lesbar.")
            } else {
                let names = ListFormatter.localizedString(byJoining: connectorIDs.map(BankingGate.displayName(forConnectorID:)))
                text = String(localized: "Verbindungen über \(names) sind gesperrt, weil diese Version eine Sicherheitslücke oder einen schweren Fehler im Bankzugang enthält. Ihre Daten bleiben lesbar.")
            }
            text += " "
            text += updateAvailable
                ? String(localized: "Bitte aktualisieren Sie GiroCrab.")
                : String(localized: "Ein Update ist in Vorbereitung.")
            return text
        }
    }

    /// "fints" → "FinTS", "fints:50050201" → "FinTS (BLZ 50050201)", …
    static func displayName(forConnectorID id: String) -> String {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        let base: String
        switch parts.first ?? id {
        case "fints": base = "FinTS"
        case "comdirect": base = "comdirect"
        case "paypal": base = "PayPal"
        case "traderepublic": base = "Trade Republic"
        case "enablebanking": base = "Enable Banking"
        case "bunq": base = "bunq"
        case "scalable": base = "Scalable Capital"
        case "amazon-orders": base = "Amazon"
        default: base = parts.first ?? id
        }
        guard parts.count == 2 else { return base }
        if base == "FinTS" { return "\(base) (BLZ \(parts[1]))" }
        return "\(base) (\(parts[1]))"
    }
}

// MARK: - Pure evaluation (unit-tested)

public enum BankingPolicyEvaluation {
    /// Ed25519 over the exact bytes; any of `keys` may have signed.
    public static func verify(json: Data, signature: Data, keys: [Curve25519.Signing.PublicKey]) -> Bool {
        keys.contains { $0.isValidSignature(signature, for: json) }
    }

    /// The block for this build, or nil. Several matching rules: the strictest
    /// wins (union of blocked connectors, "update in preparation" if any rule says so).
    public static func gate(
        for document: BankingPolicyDocument,
        distribution: BankingDistribution,
        bundleVersion: String
    ) -> BankingGate? {
        let channel = AppUpdateChannel.inferred(fromBundleVersion: bundleVersion)
        let blocking = document.rules.filter { rule in
            rule.distributions.contains(distribution)
                && (rule.channels?.contains(channel) ?? true)
                && !rule.minimumVersion.isEmpty
                && BankingVersion.compare(bundleVersion, rule.minimumVersion) == .orderedAscending
        }
        guard !blocking.isEmpty else { return nil }
        let all = blocking.contains { $0.connectors == nil || $0.connectors?.isEmpty == true }
        var ids: [String] = []
        if !all {
            for id in blocking.flatMap({ $0.connectors ?? [] }) where !ids.contains(id) { ids.append(id) }
        }
        let strictestVersion = blocking.map(\.minimumVersion).max { BankingVersion.compare($0, $1) == .orderedAscending }
        return BankingGate(
            reason: .outdated,
            all: all,
            connectorIDs: ids,
            minimumVersion: strictestVersion,
            advisory: blocking.compactMap(\.advisory).first,
            updateAvailable: blocking.allSatisfy(\.updateAvailable)
        )
    }

    /// Same rule as the core (`banking_gate::connector_id_matches`).
    public static func connectorID(_ id: String, matches key: String) -> Bool {
        let id = id.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return false }
        return key == id || key.hasPrefix(id + ":")
    }
}

/// Sparkle's `SUStandardVersionComparator`, rebuilt because GiroCrabUI does not
/// link Sparkle (App Store / iOS). Test vectors come from Sparkle itself
/// (BankingPolicyTests). `0.7.2b1` < `0.7.2` < `0.7.2.20261112`.
public enum BankingVersion {
    private enum Kind { case number, string, period, separator }
    private typealias Part = (kind: Kind, text: String)

    private static func kind(_ c: Character) -> Kind {
        if c == "." { return .period }
        if c.isASCII && c.isNumber { return .number }
        if c.isWhitespace || c.isPunctuation { return .separator }
        return .string // letters, but also symbols like "+"
    }

    private static func split(_ s: String) -> [Part] {
        // Sparkle ignores everything from the first "-" on ("0.7.2-beta.1" == "0.7.2").
        let s = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        var parts: [Part] = []
        for c in s {
            let k = kind(c)
            if let last = parts.last, last.kind == k, k == .number || k == .string {
                parts[parts.count - 1].text.append(c)
            } else {
                parts.append((k, String(c)))
            }
        }
        return parts
    }

    /// Number of leading `N(.N)*` parts, or nil if ".." follows them
    /// ("1..0" – Sparkle does not pad then).
    private static func numericPrefix(_ p: [Part]) -> Int? {
        var i = 0
        guard i < p.count, p[i].kind == .number else { return nil }
        i += 1
        while i + 1 < p.count, p[i].kind == .period, p[i + 1].kind == .number { i += 2 }
        if i + 1 < p.count, p[i].kind == .period, p[i + 1].kind == .period { return nil }
        return i
    }

    /// Pads the shorter numeric prefix with ".0" so that 1.0 == 1.0.0 and 1.0b1 == 1.0.0b1.
    private static func pad(_ a: inout [Part], _ b: inout [Part]) {
        guard let na = numericPrefix(a), let nb = numericPrefix(b), na != nb else { return }
        let zeros = { (n: Int) in (0..<(n / 2)).flatMap { _ in [Part(.period, "."), Part(.number, "0")] } }
        if na < nb { a.insert(contentsOf: zeros(nb - na), at: na) } else { b.insert(contentsOf: zeros(na - nb), at: nb) }
    }

    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        var pa = split(a), pb = split(b)
        pad(&pa, &pb)
        for i in 0..<min(pa.count, pb.count) {
            let (ka, sa) = pa[i], (kb, sb) = pb[i]
            if ka == kb {
                switch ka {
                case .number:
                    let na = Decimal(string: sa) ?? 0, nb = Decimal(string: sb) ?? 0
                    if na != nb { return na < nb ? .orderedAscending : .orderedDescending }
                case .string:
                    let r = sa.compare(sb)
                    if r != .orderedSame { return r }
                default:
                    continue
                }
            } else if kb == .string {
                return .orderedDescending
            } else if ka == .string {
                return .orderedAscending
            } else {
                return ka == .number ? .orderedDescending : .orderedAscending
            }
        }
        guard pa.count != pb.count else { return .orderedSame }
        // The rest of the longer one decides: its first part that is not a
        // "." – a string makes it older (1.0 > 1.0b1), anything else newer.
        let aLonger = pa.count > pb.count
        let rest = aLonger ? pa[pb.count...] : pb[pa.count...]
        guard let decisive = rest.first(where: { $0.kind != .period }) else { return .orderedSame }
        let longerIsNewer = decisive.kind != .string
        return (aLonger == longerIsNewer) ? .orderedDescending : .orderedAscending
    }
}

// MARK: - Storage and network (protocols for tests)

/// The last accepted policy plus whether a policy was ever verified online
/// on this device ("ohne Prüfung kein Bankkontakt").
public struct StoredBankingPolicy: Codable, Equatable, Sendable {
    public var json: Data
    public var signature: Data
    public var verifiedOnline: Bool
}

public protocol BankingPolicyStore: Sendable {
    func load() -> StoredBankingPolicy?
    func save(_ policy: StoredBankingPolicy) throws
}

public protocol BankingPolicyFetcher: Sendable {
    /// Returns the JSON bytes and the detached signature.
    func fetch() async throws -> (json: Data, signature: Data)
}

/// Non-synchronised keychain item: survives `brew uninstall --zap`, deleting
/// Application Support and reinstalling (anti-rollback of `sequence`).
public struct KeychainBankingPolicyStore: BankingPolicyStore {
    let service = "de.girocrab.banking-policy"
    let account = "policy"

    public init() {}

    private func baseQuery(dataProtection: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        #if os(macOS)
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return q
    }

    public func load() -> StoredBankingPolicy? {
        for dp in [true, false] {
            var q = baseQuery(dataProtection: dp)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data {
                return try? JSONDecoder().decode(StoredBankingPolicy.self, from: data)
            }
        }
        return nil
    }

    public func save(_ policy: StoredBankingPolicy) throws {
        let data = try JSONEncoder().encode(policy)
        // Data-protection keychain first; unsigned/ad-hoc macOS builds lack the
        // entitlement (errSecMissingEntitlement) and use the login keychain,
        // like VaultKeyManager.
        var lastStatus: OSStatus = errSecSuccess
        for dp in [true, false] {
            let q = baseQuery(dataProtection: dp)
            let attrs: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(q.merging(attrs) { $1 } as CFDictionary, nil)
            }
            if status == errSecSuccess { return }
            lastStatus = status
            if status != errSecMissingEntitlement { break }
        }
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(lastStatus))
    }
}

/// HTTPS download without cookies, cache or user data; at most 64 KB, 10 s.
public struct URLSessionBankingPolicyFetcher: BankingPolicyFetcher {
    public static let maxBytes = 64 * 1024
    let url: URL

    public init(url: URL) { self.url = url }

    public func fetch() async throws -> (json: Data, signature: Data) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        async let json = get(url, session)
        async let sig = get(url.appendingPathExtension("sig"), session)
        return try await (json, sig)
    }

    private func get(_ url: URL, _ session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(nil, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard data.count <= Self.maxBytes else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }
}

// MARK: - Controller

@MainActor
@Observable
public final class BankingPolicy {
    /// Policy public keys (Ed25519, raw 32 bytes, base64). An array so the key
    /// can be rotated (docs/banking-policy.md). Entries that are not valid keys
    /// – like the placeholder – are ignored; without a valid key the whole
    /// feature is off: no request, no block.
    /// `scripts/banking-policy.sh keygen` / `rotate-key` edit this list.
    nonisolated public static let publicKeys: [String] = [
        "PLACEHOLDER-BANKING-POLICY-PUBLIC-KEY", // banking-policy-public-key
    ]

    nonisolated public static let defaultURL = URL(string: "https://github.com/GiroCrab/GiroCrab/releases/latest/download/banking-policy.json")!

    /// A successful check is "fresh" for this long (also the minimum interval between downloads).
    nonisolated public static let freshness: TimeInterval = 15 * 60

    public static let shared = BankingPolicy.makeDefault()

    // Inputs
    @ObservationIgnored let keys: [Curve25519.Signing.PublicKey]
    @ObservationIgnored let store: BankingPolicyStore
    @ObservationIgnored let fetcher: BankingPolicyFetcher?
    @ObservationIgnored let bundled: (json: Data, signature: Data)?
    @ObservationIgnored let distribution: BankingDistribution
    @ObservationIgnored let bundleVersion: String
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored private var inFlight: Task<Void, Never>?

    // State
    /// False while no valid public key is compiled in (placeholder).
    public let isEnabled: Bool
    public private(set) var document: BankingPolicyDocument?
    public private(set) var verifiedOnline = false
    public private(set) var lastSuccessfulCheck: Date?
    public private(set) var lastFailure: String?
    /// The block for this build (nil = banking allowed).
    public private(set) var gate: BankingGate?

    public init(
        publicKeys: [String],
        store: BankingPolicyStore,
        fetcher: BankingPolicyFetcher?,
        bundled: (json: Data, signature: Data)?,
        distribution: BankingDistribution,
        bundleVersion: String,
        now: @escaping () -> Date = Date.init
    ) {
        let keys = publicKeys.compactMap { Data(base64Encoded: $0) }
            .compactMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
        self.keys = keys
        self.isEnabled = !keys.isEmpty
        self.store = store
        self.fetcher = fetcher
        self.bundled = bundled
        self.distribution = distribution
        self.bundleVersion = bundleVersion
        self.now = now
        loadLocal()
    }

    static func makeDefault() -> BankingPolicy {
        var keys = publicKeys
        var url = defaultURL
        var version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        #if DEBUG
        // Test hooks for throwaway keys and a local server. Not compiled into
        // release builds, so nobody can redirect or disable the check there.
        let env = ProcessInfo.processInfo.environment
        if let k = env["GIROCRAB_BANKING_POLICY_KEY"], !k.isEmpty { keys = [k] }
        if let u = env["GIROCRAB_BANKING_POLICY_URL"].flatMap(URL.init(string:)) { url = u }
        if let v = env["GIROCRAB_BANKING_POLICY_VERSION"], !v.isEmpty { version = v }
        #endif
        let bundledJSON = Bundle.main.url(forResource: "banking-policy", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
        let bundledSig = Bundle.main.url(forResource: "banking-policy.json", withExtension: "sig")
            .flatMap { try? Data(contentsOf: $0) }
        let bundled = bundledJSON.flatMap { j in bundledSig.map { (json: j, signature: $0) } }
        return BankingPolicy(
            publicKeys: keys,
            store: KeychainBankingPolicyStore(),
            fetcher: URLSessionBankingPolicyFetcher(url: url),
            bundled: bundled,
            distribution: .current,
            bundleVersion: version
        )
    }

    /// True when the debug overrides are in use (shown in settings).
    public static var usesDebugOverrides: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        return env["GIROCRAB_BANKING_POLICY_KEY"] != nil || env["GIROCRAB_BANKING_POLICY_URL"] != nil
            || env["GIROCRAB_BANKING_POLICY_VERSION"] != nil
        #else
        return false
        #endif
    }

    /// Block for one connection key (`BankConnection.connector`), or nil.
    public func gate(for connectorKey: String) -> BankingGate? {
        guard let gate else { return nil }
        if gate.all { return gate }
        return gate.connectorIDs.contains { BankingPolicyEvaluation.connectorID($0, matches: connectorKey) } ? gate : nil
    }

    /// Any block at all (for the banner).
    public var isBlocking: Bool { gate != nil }

    // MARK: Loading

    private func verifiedDocument(json: Data, signature: Data) -> BankingPolicyDocument? {
        guard BankingPolicyEvaluation.verify(json: json, signature: signature, keys: keys) else { return nil }
        return try? BankingPolicyDocument.parse(json)
    }

    /// Stored (keychain) and bundled policy; the higher `sequence` wins.
    private func loadLocal() {
        guard isEnabled else { apply(); return }
        var stored = store.load()
        var storedDoc = stored.flatMap { verifiedDocument(json: $0.json, signature: $0.signature) }
        if storedDoc == nil { stored = stored.map { StoredBankingPolicy(json: Data(), signature: Data(), verifiedOnline: $0.verifiedOnline) } }
        let wasOnline = stored?.verifiedOnline ?? false
        if let bundled, let bundledDoc = verifiedDocument(json: bundled.json, signature: bundled.signature),
           bundledDoc.sequence > (storedDoc?.sequence ?? 0) || storedDoc == nil {
            storedDoc = bundledDoc
            stored = StoredBankingPolicy(json: bundled.json, signature: bundled.signature, verifiedOnline: wasOnline)
            try? store.save(stored!)
        }
        document = storedDoc
        verifiedOnline = wasOnline
        apply()
    }

    // MARK: Checking

    /// Downloads and verifies the policy if the last successful check is older
    /// than `freshness` (or `force`). Concurrent callers share one download.
    public func refresh(force: Bool = false) async {
        guard isEnabled, let fetcher else { return }
        if !force, let last = lastSuccessfulCheck, now().timeIntervalSince(last) < Self.freshness { return }
        if let inFlight { await inFlight.value; return }
        let task = Task { @MainActor in
            do {
                let (json, sig) = try await fetcher.fetch()
                self.accept(json: json, signature: sig)
            } catch {
                self.lastFailure = error.localizedDescription
                self.apply()
            }
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    /// Takes a downloaded file if signature, schema and `sequence` are valid.
    /// Anything else leaves the stored state untouched (no grace period).
    func accept(json: Data, signature: Data) {
        guard BankingPolicyEvaluation.verify(json: json, signature: signature, keys: keys) else {
            lastFailure = String(localized: "Ungültige Signatur")
            apply()
            return
        }
        let doc: BankingPolicyDocument
        do { doc = try BankingPolicyDocument.parse(json) } catch {
            lastFailure = String(localized: "Unbekanntes Format")
            apply()
            return
        }
        if let current = document, doc.sequence < current.sequence {
            lastFailure = String(localized: "Veraltete Richtlinie (sequence \(doc.sequence) < \(current.sequence))")
            apply()
            return
        }
        try? store.save(StoredBankingPolicy(json: json, signature: signature, verifiedOnline: true))
        document = doc
        verifiedOnline = true
        lastSuccessfulCheck = now()
        lastFailure = nil
        apply()
    }

    /// Recomputes `gate` and hands it to the core (second line of defence).
    private func apply() {
        let newGate: BankingGate?
        if !isEnabled {
            newGate = nil
        } else if !verifiedOnline {
            // Never verified online on this device (fresh install, or the
            // keychain item was lost): only the bundled floor is known. An
            // older build must not talk to a bank unchecked.
            let bundledGate = document.flatMap {
                BankingPolicyEvaluation.gate(for: $0, distribution: distribution, bundleVersion: bundleVersion)
            }
            let unchecked = BankingGate(
                reason: .checkUnavailable, all: true, connectorIDs: [],
                minimumVersion: nil, advisory: nil, updateAvailable: true
            )
            if let bundledGate {
                newGate = bundledGate
            } else if lastFailure == nil {
                // Not tried yet: no banner, but the core stays closed until the
                // first check (every bank entry point awaits `refresh()` first).
                if gate != nil { gate = nil }
                setBankingBlock(all: true, connectorIds: [], message: unchecked.message)
                return
            } else {
                newGate = unchecked
            }
        } else {
            newGate = document.flatMap {
                BankingPolicyEvaluation.gate(for: $0, distribution: distribution, bundleVersion: bundleVersion)
            }
        }
        if gate != newGate { gate = newGate }
        if let g = newGate {
            setBankingBlock(all: g.all, connectorIds: g.connectorIDs, message: g.message)
        } else {
            clearBankingBlock()
        }
    }
}
