import CryptoKit
import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// Security lock for bank connections (signed banking-policy.json).
@MainActor
final class BankingPolicyTests: XCTestCase {
    // Throwaway keys, generated per run – never a real policy key.
    private let key = Curve25519.Signing.PrivateKey()
    private let otherKey = Curve25519.Signing.PrivateKey()

    override func tearDown() {
        clearBankingBlock() // the core block is process-wide
        super.tearDown()
    }

    // MARK: Helpers

    private func pub(_ k: Curve25519.Signing.PrivateKey) -> String {
        k.publicKey.rawRepresentation.base64EncodedString()
    }

    private func policyJSON(sequence: UInt64, rules: String = "[]") -> Data {
        Data(#"{"schema":1,"issued":"2026-11-20T10:00:00Z","sequence":\#(sequence),"rules":\#(rules)}"#.utf8)
    }

    private func signed(_ json: Data, by k: Curve25519.Signing.PrivateKey? = nil) -> (json: Data, signature: Data) {
        (json, try! (k ?? key).signature(for: json))
    }

    private let blockFinTS = #"[{"distribution":["developer-id"],"minimumVersion":"0.7.2","connectors":["fints"],"advisory":"https://example.com/a"}]"#
    private let blockAll = #"[{"distribution":["developer-id","mac-app-store"],"minimumVersion":"0.7.2"}]"#

    private func makePolicy(
        keys: [String]? = nil,
        store: MemoryStore = MemoryStore(),
        fetcher: FakeFetcher? = FakeFetcher(),
        bundled: (json: Data, signature: Data)? = nil,
        version: String = "0.7.1",
        buildDate: Date? = nil,
        clock: Clock = Clock()
    ) -> BankingPolicy {
        BankingPolicy(
            publicKeys: keys ?? [pub(key)],
            store: store,
            fetcher: fetcher,
            bundled: bundled,
            distribution: .developerID,
            bundleVersion: version,
            buildDate: buildDate,
            now: { clock.now }
        )
    }

    // MARK: Version comparison (vectors from Sparkle 2.10.1's SUStandardVersionComparator)

    func testVersionComparisonMatchesSparkle() {
        let vectors: [(String, String, ComparisonResult)] = [
            ("0.7.2b1", "0.7.2", .orderedAscending),
            ("0.7.2", "0.7.2.20261112093000", .orderedAscending),
            ("0.7.2b1", "0.7.2b2", .orderedAscending),
            ("0.7.2b9", "0.7.2b10", .orderedAscending),
            ("0.7.1", "0.7.2b1", .orderedAscending),
            ("0.7.2", "0.7.10", .orderedAscending),
            ("0.7.2", "0.7.2", .orderedSame),
            ("0.7", "0.7.0", .orderedSame),
            ("0.7.2.20261112093000", "0.7.3b1", .orderedAscending),
            ("0.7.2.20261112093000", "0.7.2.20261113010000", .orderedAscending),
            ("1.0", "1.0a1", .orderedDescending),
            ("1.0a1", "1.0b1", .orderedAscending),
            ("0.6.0", "0.5.5", .orderedDescending),
            ("", "0.7.2", .orderedAscending),
            ("0.7.2", "0.7.2-beta.1", .orderedSame),
            ("1.0 Beta", "1.0", .orderedDescending),
            ("0.7.0", "0.7.0.0", .orderedSame),
            ("0.7.2", "0.7.2.0", .orderedSame),
            ("0.7.2", "0.7.2.1", .orderedAscending),
            ("1.0", "1.0.1", .orderedAscending),
            ("1.0", "1.0.0.0", .orderedSame),
            ("1.0-1", "1.0", .orderedSame),
            ("1.0 1", "1.0", .orderedDescending),
            ("1.0", "1.0-beta", .orderedSame),
            ("1.0b", "1.0", .orderedAscending),
            ("1.0.b1", "1.0", .orderedAscending),
            ("1.0", "1.0.0b1", .orderedDescending),
            ("1.0.0", "1.0b1", .orderedDescending),
            ("0.7.2b1", "0.7.2.0", .orderedAscending),
            ("0.7.2.0", "0.7.2.20261112", .orderedAscending),
            ("1..0", "1.0", .orderedAscending),
            ("1.0.", "1.0", .orderedSame),
            ("a", "b", .orderedAscending),
            ("1.0a", "1.0A", .orderedDescending),
            ("2", "10", .orderedAscending),
            ("007", "7", .orderedSame),
            ("1.0+1", "1.0", .orderedAscending),
            ("1.0_1", "1.0", .orderedDescending),
            ("1.0,1", "1.0", .orderedDescending),
            ("1.0-1", "1.0-2", .orderedSame),
            ("1.1-1", "1.0-2", .orderedDescending),
            ("1.0 b1", "1.0", .orderedDescending),
            ("1.0.0.1", "1.0", .orderedDescending),
            ("1.0.0.0.b", "1.0", .orderedAscending),
            ("1.0b1", "1.0.0b1", .orderedSame),
            ("1.0b1", "1.0b1.0", .orderedAscending),
        ]
        for (a, b, expected) in vectors {
            XCTAssertEqual(BankingVersion.compare(a, b), expected, "\(a) vs \(b)")
            let reverse: ComparisonResult = expected == .orderedAscending ? .orderedDescending
                : expected == .orderedDescending ? .orderedAscending : .orderedSame
            XCTAssertEqual(BankingVersion.compare(b, a), reverse, "\(b) vs \(a)")
        }
    }

    // MARK: Parsing and rule evaluation

    func testParseRejectsUnknownSchemaAndGarbage() {
        XCTAssertThrowsError(try BankingPolicyDocument.parse(Data(#"{"schema":2,"sequence":1,"rules":[]}"#.utf8))) {
            XCTAssertEqual($0 as? BankingPolicyDocument.ParseError, .unknownSchema(2))
        }
        XCTAssertThrowsError(try BankingPolicyDocument.parse(Data("nope".utf8)))
    }

    func testUnknownValuesAreIgnoredAndAdvisoryMustBeHTTPS() throws {
        let doc = try BankingPolicyDocument.parse(policyJSON(sequence: 1, rules:
            #"[{"distribution":["developer-id","vision-os"],"channels":["stable","canary"],"minimumVersion":"1.0","advisory":"http://example.com"}]"#))
        XCTAssertEqual(doc.rules[0].distributions, [.developerID])
        XCTAssertEqual(doc.rules[0].channels, [.stable])
        XCTAssertNil(doc.rules[0].advisory)
        XCTAssertTrue(doc.rules[0].updateAvailable)
    }

    func testChannelOfRunningBuildDecides() throws {
        let doc = try BankingPolicyDocument.parse(policyJSON(sequence: 1, rules:
            #"[{"distribution":["developer-id"],"channels":["nightly"],"minimumVersion":"0.7.2.20261120000000"}]"#))
        // Nightly-only rule: stable and beta builds are untouched.
        XCTAssertNil(BankingPolicyEvaluation.gate(for: doc, distribution: .developerID, bundleVersion: "0.7.1"))
        XCTAssertNil(BankingPolicyEvaluation.gate(for: doc, distribution: .developerID, bundleVersion: "0.7.2b1"))
        XCTAssertNotNil(BankingPolicyEvaluation.gate(for: doc, distribution: .developerID, bundleVersion: "0.7.2.20261112093000"))
        XCTAssertNil(BankingPolicyEvaluation.gate(for: doc, distribution: .developerID, bundleVersion: "0.7.2.20261121000000"))
    }

    func testDistributionFilterAndBetaCaveat() throws {
        let doc = try BankingPolicyDocument.parse(policyJSON(sequence: 1, rules: blockFinTS))
        XCTAssertNil(BankingPolicyEvaluation.gate(for: doc, distribution: .macAppStore, bundleVersion: "0.7.1"))
        XCTAssertNotNil(BankingPolicyEvaluation.gate(for: doc, distribution: .developerID, bundleVersion: "0.7.1"))
        // 0.7.2b1 is older than 0.7.2 – minimum 0.7.2 also blocks its betas.
        XCTAssertNotNil(BankingPolicyEvaluation.gate(for: doc, distribution: .developerID, bundleVersion: "0.7.2b1"))
        XCTAssertNil(BankingPolicyEvaluation.gate(for: doc, distribution: .developerID, bundleVersion: "0.7.2"))
        XCTAssertNil(BankingPolicyEvaluation.gate(for: doc, distribution: .developerID, bundleVersion: "0.7.2.20261112093000"))
    }

    func testStrictestRuleWins() throws {
        let doc = try BankingPolicyDocument.parse(policyJSON(sequence: 1, rules: #"""
            [{"distribution":["developer-id"],"minimumVersion":"0.7.2","connectors":["fints"]},
             {"distribution":["developer-id"],"minimumVersion":"0.8.0","connectors":["bunq","fints"],"updateAvailable":false},
             {"distribution":["developer-id"],"minimumVersion":"0.6.0"}]
            """#))
        let g = try XCTUnwrap(BankingPolicyEvaluation.gate(for: doc, distribution: .developerID, bundleVersion: "0.7.5"))
        XCTAssertFalse(g.all) // the "all" rule (0.6.0) does not apply to 0.7.5
        XCTAssertEqual(g.connectorIDs, ["bunq", "fints"])
        XCTAssertFalse(g.updateAvailable)
        XCTAssertEqual(g.minimumVersion, "0.8.0")
        let all = try XCTUnwrap(BankingPolicyEvaluation.gate(for: doc, distribution: .developerID, bundleVersion: "0.5.0"))
        XCTAssertTrue(all.all)
    }

    func testConnectorIDMatchingEqualsCore() {
        for (id, key) in [("fints", "fints:50050201"), ("fints:50050201", "fints:50050201"), ("enablebanking", "enablebanking:amex"), ("bunq", "bunqx"), ("fin", "fints"), ("", "fints")] {
            XCTAssertEqual(BankingPolicyEvaluation.connectorID(id, matches: key), isBankingBlockedAfterSetting(id, key), "\(id) / \(key)")
        }
    }

    private func isBankingBlockedAfterSetting(_ id: String, _ key: String) -> Bool {
        setBankingBlock(all: false, connectorIds: [id], message: "x")
        defer { clearBankingBlock() }
        return isBankingBlocked(key: key)
    }

    func testMessages() {
        let partial = BankingGate(reason: .outdated, all: false, connectorIDs: ["fints", "enablebanking:amex"], minimumVersion: "0.7.2", advisory: nil, updateAvailable: false)
        XCTAssertTrue(partial.message.contains("FinTS"))
        XCTAssertTrue(partial.message.contains("Enable Banking (amex)"))
        XCTAssertTrue(partial.message.hasSuffix(String(localized: "Ein Update ist in Vorbereitung.")))
    }

    // MARK: Controller

    func testPlaceholderKeyDisablesEverything() async {
        let fetcher = FakeFetcher()
        let p = makePolicy(keys: BankingPolicy.publicKeys, fetcher: fetcher)
        XCTAssertFalse(p.isEnabled)
        await p.refresh(force: true)
        XCTAssertEqual(fetcher.calls, 0)
        XCTAssertNil(p.gate)
        XCTAssertFalse(isBankingBlocked(key: "fints:50050201"))
    }

    func testShippedKeysAreOnlyPlaceholders() {
        // Until the maintainer adds a real key the feature must stay off.
        XCTAssertTrue(BankingPolicy.publicKeys.allSatisfy { Data(base64Encoded: $0) == nil })
    }

    func testSignatureChecks() async {
        let fetcher = FakeFetcher()
        let p = makePolicy(keys: [pub(key), pub(otherKey)], fetcher: fetcher)
        // Unsigned / wrong key / tampered → ignored.
        fetcher.result = .success((policyJSON(sequence: 5, rules: blockAll), Data(repeating: 0, count: 64)))
        await p.refresh(force: true)
        XCTAssertNil(p.document)
        let foreign = Curve25519.Signing.PrivateKey()
        fetcher.result = .success(signed(policyJSON(sequence: 5, rules: blockAll), by: foreign))
        await p.refresh(force: true)
        XCTAssertNil(p.document)
        var tampered = signed(policyJSON(sequence: 5, rules: "[]"))
        tampered.json = policyJSON(sequence: 5, rules: blockAll)
        fetcher.result = .success(tampered)
        await p.refresh(force: true)
        XCTAssertNil(p.document)
        // Second key during a rotation → accepted.
        fetcher.result = .success(signed(policyJSON(sequence: 5, rules: blockAll), by: otherKey))
        await p.refresh(force: true)
        XCTAssertEqual(p.document?.sequence, 5)
        XCTAssertEqual(p.gate?.all, true)
        XCTAssertTrue(isBankingBlocked(key: "comdirect"))
    }

    func testSequenceRollbackIsRejected() async {
        let fetcher = FakeFetcher()
        let p = makePolicy(fetcher: fetcher)
        fetcher.result = .success(signed(policyJSON(sequence: 7, rules: blockAll)))
        await p.refresh(force: true)
        XCTAssertNotNil(p.gate)
        // Older, correctly signed file without a block: must not lift it.
        fetcher.result = .success(signed(policyJSON(sequence: 6)))
        await p.refresh(force: true)
        XCTAssertEqual(p.document?.sequence, 7)
        XCTAssertNotNil(p.gate)
        XCTAssertNotNil(p.lastFailure)
        // Newer file without a block lifts it.
        fetcher.result = .success(signed(policyJSON(sequence: 8)))
        await p.refresh(force: true)
        XCTAssertNil(p.gate)
        XCTAssertFalse(isBankingBlocked(key: "comdirect"))
    }

    func testPersistenceSurvivesRestartOfflineAndUpdateLiftsBlock() async {
        let store = MemoryStore()
        let fetcher = FakeFetcher()
        let p = makePolicy(store: store, fetcher: fetcher)
        fetcher.result = .success(signed(policyJSON(sequence: 3, rules: blockFinTS)))
        await p.refresh(force: true)
        XCTAssertNotNil(p.gate(for: "fints:52090000"))
        XCTAssertNil(p.gate(for: "comdirect"))

        // Restart (e.g. after `brew uninstall --zap`): keychain still has it, offline.
        let offline = FakeFetcher(result: .failure(URLError(.notConnectedToInternet)))
        let restarted = makePolicy(store: store, fetcher: offline)
        await restarted.refresh(force: true)
        XCTAssertNotNil(restarted.gate(for: "fints:52090000"))
        XCTAssertTrue(isBankingBlocked(key: "fints:52090000"))
        XCTAssertFalse(isBankingBlocked(key: "comdirect"))

        // Updated app (meets the minimum version) with the same stored file.
        let updated = makePolicy(store: store, fetcher: offline, version: "0.7.2")
        XCTAssertNil(updated.gate)
        XCTAssertFalse(isBankingBlocked(key: "fints:52090000"))
    }

    func testBundledFloor() async {
        let store = MemoryStore()
        store.value = StoredBankingPolicy(json: policyJSON(sequence: 4), signature: try! key.signature(for: policyJSON(sequence: 4)), verifiedOnline: true)
        // Higher bundled sequence replaces the stored one (and keeps "verified online").
        let bundledHigh = signed(policyJSON(sequence: 9, rules: blockAll))
        let p = makePolicy(store: store, fetcher: nil, bundled: bundledHigh)
        XCTAssertEqual(p.document?.sequence, 9)
        XCTAssertEqual(store.value?.json, bundledHigh.json)
        XCTAssertEqual(store.value?.verifiedOnline, true)
        XCTAssertEqual(p.gate?.reason, .outdated)
        // Lower bundled sequence does not.
        let bundledLow = signed(policyJSON(sequence: 2))
        let q = makePolicy(store: store, fetcher: nil, bundled: bundledLow)
        XCTAssertEqual(q.document?.sequence, 9)
    }

    func testNoBankContactWithoutAnyOnlineCheck() async {
        // Fresh install: only the bundled policy (no block), never verified online.
        let fetcher = FakeFetcher(result: .failure(URLError(.cannotConnectToHost)))
        let p = makePolicy(fetcher: fetcher, bundled: signed(policyJSON(sequence: 1)), version: "9.9.9")
        // Before the first attempt: no banner, but the core is closed.
        XCTAssertNil(p.gate)
        XCTAssertTrue(isBankingBlocked(key: "comdirect"))
        await p.refresh()
        XCTAssertEqual(p.gate?.reason, .checkUnavailable)
        XCTAssertEqual(p.gate?.all, true)
        // GitHub reachable again → allowed.
        fetcher.result = .success(signed(policyJSON(sequence: 1)))
        await p.refresh(force: true)
        XCTAssertNil(p.gate)
        XCTAssertFalse(isBankingBlocked(key: "comdirect"))
    }

    private let day: TimeInterval = 24 * 60 * 60

    func testFreshBuildWorksWithoutGitHubFor90Days() async {
        // Little Snitch: GitHub never reachable, only the bank servers.
        let clock = Clock()
        let fetcher = FakeFetcher(result: .failure(URLError(.cannotConnectToHost)))
        let p = makePolicy(
            fetcher: fetcher, bundled: signed(policyJSON(sequence: 1)), version: "9.9.9",
            buildDate: clock.now.addingTimeInterval(-30 * day), clock: clock
        )
        XCTAssertTrue(p.reliesOnBundledPolicy)
        XCTAssertEqual(p.bundledPolicyValidUntil, clock.now.addingTimeInterval(60 * day))
        XCTAssertNil(p.gate)
        XCTAssertFalse(isBankingBlocked(key: "comdirect"))
        await p.refresh()
        XCTAssertNil(p.gate)
        XCTAssertFalse(isBankingBlocked(key: "comdirect"))
        // Day 89 after the build: still allowed.
        clock.now = clock.now.addingTimeInterval(59 * day)
        await p.refresh(force: true)
        XCTAssertNil(p.gate)
        // Day 91: the bundled policy is too old to vouch for this build.
        clock.now = clock.now.addingTimeInterval(2 * day)
        await p.refresh(force: true)
        XCTAssertFalse(p.reliesOnBundledPolicy)
        XCTAssertEqual(p.gate?.reason, .checkUnavailable)
        XCTAssertTrue(isBankingBlocked(key: "comdirect"))
        // GitHub reachable once → normal operation, the grace no longer matters.
        fetcher.result = .success(signed(policyJSON(sequence: 1)))
        await p.refresh(force: true)
        XCTAssertNil(p.gate)
        XCTAssertFalse(p.reliesOnBundledPolicy)
        XCTAssertFalse(isBankingBlocked(key: "comdirect"))
    }

    func testBundledBlockAppliesDuringGracePeriod() async {
        let clock = Clock()
        let p = makePolicy(
            fetcher: FakeFetcher(result: .failure(URLError(.timedOut))),
            bundled: signed(policyJSON(sequence: 1, rules: blockFinTS)), version: "0.7.1",
            buildDate: clock.now, clock: clock
        )
        XCTAssertEqual(p.gate?.reason, .outdated)
        XCTAssertTrue(isBankingBlocked(key: "fints:50050201"))
        XCTAssertFalse(isBankingBlocked(key: "comdirect"))
    }

    func testNoGraceWithoutBuildDateOrValidBundledPolicy() async {
        let clock = Clock()
        // Xcode / swift run: no GiroCrabBuildDate.
        let noDate = makePolicy(bundled: signed(policyJSON(sequence: 1)), version: "9.9.9", clock: clock)
        XCTAssertNil(noDate.bundledPolicyValidUntil)
        XCTAssertTrue(isBankingBlocked(key: "comdirect"))
        // No bundled policy at all.
        let noPolicy = makePolicy(version: "9.9.9", buildDate: clock.now, clock: clock)
        XCTAssertNil(noPolicy.bundledPolicyValidUntil)
        XCTAssertTrue(isBankingBlocked(key: "comdirect"))
        // Bundled policy signed by a foreign key.
        let forged = makePolicy(
            bundled: signed(policyJSON(sequence: 1), by: otherKey), version: "9.9.9",
            buildDate: clock.now, clock: clock
        )
        XCTAssertNil(forged.bundledPolicyValidUntil)
        XCTAssertTrue(isBankingBlocked(key: "comdirect"))
    }

    func testStoredStateKeepsWorkingWhenGitHubIsDown() async {
        let store = MemoryStore()
        let fetcher = FakeFetcher(result: .success(signed(policyJSON(sequence: 1))))
        await makePolicy(store: store, fetcher: fetcher, version: "9.9.9").refresh(force: true)
        let down = FakeFetcher(result: .failure(URLError(.timedOut)))
        let p = makePolicy(store: store, fetcher: down, version: "9.9.9")
        await p.refresh(force: true)
        XCTAssertNil(p.gate)
        XCTAssertFalse(isBankingBlocked(key: "comdirect"))
    }

    func testRefreshIsThrottled() async {
        let clock = Clock()
        let fetcher = FakeFetcher(result: .success(signed(policyJSON(sequence: 1))))
        let p = makePolicy(fetcher: fetcher, clock: clock)
        await p.refresh()
        await p.refresh()
        XCTAssertEqual(fetcher.calls, 1)
        clock.now += BankingPolicy.freshness + 1
        await p.refresh()
        XCTAssertEqual(fetcher.calls, 2)
        await p.refresh(force: true)
        XCTAssertEqual(fetcher.calls, 3)
    }
}

// MARK: - Test doubles

final class MemoryStore: BankingPolicyStore, @unchecked Sendable {
    var value: StoredBankingPolicy?
    func load() -> StoredBankingPolicy? { value }
    func save(_ policy: StoredBankingPolicy) throws { value = policy }
}

final class FakeFetcher: BankingPolicyFetcher, @unchecked Sendable {
    var result: Result<(Data, Data), Error>
    var calls = 0
    init(result: Result<(Data, Data), Error> = .failure(URLError(.notConnectedToInternet))) { self.result = result }
    func fetch() async throws -> (json: Data, signature: Data) {
        calls += 1
        let (j, s) = try result.get()
        return (j, s)
    }
}

final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}
