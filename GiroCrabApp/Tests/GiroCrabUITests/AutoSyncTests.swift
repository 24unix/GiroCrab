import XCTest
@testable import GiroCrabUI

/// Scheduled balance fetch (GiroCrab/GiroCrab#546): interval, skipping while
/// the vault is locked, catching up after the unlock, and what the menu bar
/// popover may say about it.
final class AutoSyncTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var unix: Int64 { Int64(now.timeIntervalSince1970) }
    private func hoursAgo(_ h: Double) -> Int64 { unix - Int64(h * 3600) }

    func testOffIsTheDefaultAndNegativeOrMissingMeansOff() {
        XCTAssertEqual(AutoSync.hours(stored: nil), 0)
        XCTAssertEqual(AutoSync.hours(stored: -1), 0)
        XCTAssertEqual(AutoSync.hours(stored: 6), 6)
        XCTAssertEqual(AutoSync.hourOptions.first, 0)
        XCTAssertEqual(AutoSync.hourOptions, [0, 1, 2, 4, 6, 12, 24])
    }

    func testDueOnlyAfterTheIntervalHasPassed() {
        XCTAssertTrue(AutoSync.isDue(lastSyncUnix: nil, lastAttemptUnix: nil, hours: 4, now: now), "never fetched")
        XCTAssertFalse(AutoSync.isDue(lastSyncUnix: hoursAgo(3.9), lastAttemptUnix: nil, hours: 4, now: now))
        XCTAssertTrue(AutoSync.isDue(lastSyncUnix: hoursAgo(4), lastAttemptUnix: nil, hours: 4, now: now))
        XCTAssertFalse(AutoSync.isDue(lastSyncUnix: nil, lastAttemptUnix: nil, hours: 0, now: now), "off is never due")
    }

    func testEveryOfferedIntervalIsHonoured() {
        for h in AutoSync.hourOptions where h > 0 {
            XCTAssertFalse(AutoSync.isDue(lastSyncUnix: hoursAgo(Double(h) - 0.01), lastAttemptUnix: nil, hours: h, now: now))
            XCTAssertTrue(AutoSync.isDue(lastSyncUnix: hoursAgo(Double(h)), lastAttemptUnix: nil, hours: h, now: now))
        }
    }

    func testARecentAttemptDelaysTheNextOneEvenWhenTheLastFetchIsOld() {
        // a login that needs a TAN fails without a fetch: no retry at every tick
        XCTAssertFalse(AutoSync.isDue(lastSyncUnix: hoursAgo(30), lastAttemptUnix: hoursAgo(1), hours: 6, now: now))
        XCTAssertTrue(AutoSync.isDue(lastSyncUnix: hoursAgo(30), lastAttemptUnix: hoursAgo(7), hours: 6, now: now))
        // a manual fetch newer than the last attempt counts as well
        XCTAssertFalse(AutoSync.isDue(lastSyncUnix: hoursAgo(1), lastAttemptUnix: hoursAgo(30), hours: 6, now: now))
    }

    func testLockedVaultSkipsTheFetchAndDoesNotConsumeIt() {
        XCTAssertEqual(AutoSync.decide(hours: 2, isUnlocked: false, lastSyncUnix: hoursAgo(10), lastAttemptUnix: nil, now: now),
                       .skippedLocked)
        // nothing was recorded while locked, so the first tick after the unlock runs it
        XCTAssertEqual(AutoSync.decide(hours: 2, isUnlocked: true, lastSyncUnix: hoursAgo(10), lastAttemptUnix: nil, now: now),
                       .run)
    }

    func testDecisionOrder() {
        XCTAssertEqual(AutoSync.decide(hours: 0, isUnlocked: true, lastSyncUnix: nil, lastAttemptUnix: nil, now: now), .off)
        // off wins over locked: a disabled interval is not a "skipped" fetch
        XCTAssertEqual(AutoSync.decide(hours: 0, isUnlocked: false, lastSyncUnix: nil, lastAttemptUnix: nil, now: now), .off)
        XCTAssertEqual(AutoSync.decide(hours: 6, isUnlocked: true, lastSyncUnix: hoursAgo(1), lastAttemptUnix: nil, now: now), .notDue)
    }

    func testTheIntervalSurvivesARelaunch() {
        // one name for both instances: the second one is "the next app start"
        let suite = "AutoSyncTests.relaunch.\(UUID().uuidString)"
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        UserDefaults(suiteName: suite)!.set(12, forKey: AutoSync.hoursKey)
        // a new UserDefaults instance = the next app start
        let stored = UserDefaults(suiteName: suite)!.object(forKey: AutoSync.hoursKey) as? Int
        XCTAssertEqual(AutoSync.hours(stored: stored), 12)
    }

    // MARK: popover notices

    func testNoticesNeverCarryDetailWhileLockedOrPrivate() {
        let status = AutoSyncStatus(lastRun: now, failureDetail: "Musterbank: Konto DE89370400440532013000 abgelehnt")
        for visibility in [MenuBarSummary.Visibility.locked, .covered] {
            let text = status.notice(visibility, intervalOn: true).joined(separator: " ")
            XCTAssertFalse(text.contains("Musterbank"), "no bank name while \(visibility)")
            XCTAssertFalse(text.contains("DE89"), "no IBAN while \(visibility)")
        }
        XCTAssertTrue(status.notice(.visible, intervalOn: true).joined().contains("Musterbank"))
    }

    func testLockedNoticeOnlyWhenTheIntervalIsOn() {
        let status = AutoSyncStatus()
        XCTAssertEqual(status.notice(.locked, intervalOn: true).count, 1)
        XCTAssertTrue(status.notice(.locked, intervalOn: false).isEmpty)
        XCTAssertTrue(status.notice(.visible, intervalOn: true).isEmpty, "nothing to say without a failure")
        XCTAssertTrue(status.notice(.covered, intervalOn: true).isEmpty)
    }

    func testPrivateNoticeNamesTheFailureWithoutDetail() {
        let status = AutoSyncStatus(lastRun: now, failureDetail: "geheim")
        XCTAssertEqual(status.notice(.covered, intervalOn: false).count, 1)
        XCTAssertFalse(status.notice(.covered, intervalOn: false)[0].contains("geheim"))
    }
}
