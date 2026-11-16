import Foundation

/// Interval logic of the scheduled balance fetch (Einstellungen › Allgemein ›
/// „Automatischer Abruf“, GiroCrab/GiroCrab#546). Pure functions: the loop in
/// `AppModel.autoSyncTick` only asks them, so the rules are unit-tested.
enum AutoSync {
    /// Hours between two automatic fetches, stored in `UserDefaults` (0 = off).
    /// Outside the vault on purpose: it is known while the vault is locked and
    /// right after a relaunch, before anything is unlocked.
    static let hoursKey = "autoSync.hours"
    /// Last automatic attempt per connection (`autoSync.attempt.<id>`, Unix seconds).
    static let attemptKeyPrefix = "autoSync.attempt."
    /// Offered in the picker; 0 = off (default).
    static let hourOptions = [0, 1, 2, 4, 6, 12, 24]

    enum Decision: Equatable {
        /// Interval off.
        case off
        /// Due or not, vault locked: nothing runs, the next tick after the
        /// unlock catches up (nothing is queued, the last fetch time is unchanged).
        case skippedLocked
        case notDue
        case run
    }

    /// Stored hours: a missing, negative or unparsable value means off.
    static func hours(stored: Int?) -> Int { max(0, stored ?? 0) }

    /// Due when no fetch or attempt is known, or the newer of the two is at
    /// least `hours` ago. The attempt counts too: a login that needs a TAN
    /// would otherwise be retried at every tick.
    static func isDue(lastSyncUnix: Int64?, lastAttemptUnix: Int64?, hours: Int, now: Date) -> Bool {
        guard hours > 0 else { return false }
        guard let last = [lastSyncUnix, lastAttemptUnix].compactMap({ $0 }).max() else { return true }
        return now.timeIntervalSince1970 - TimeInterval(last) >= TimeInterval(hours) * 3600
    }

    static func decide(hours: Int, isUnlocked: Bool, lastSyncUnix: Int64?, lastAttemptUnix: Int64?, now: Date) -> Decision {
        guard hours > 0 else { return .off }
        guard isUnlocked else { return .skippedLocked }
        return isDue(lastSyncUnix: lastSyncUnix, lastAttemptUnix: lastAttemptUnix, hours: hours, now: now) ? .run : .notDue
    }

    static func attemptKey(_ connectionID: Int64) -> String { attemptKeyPrefix + String(connectionID) }

    /// Picker / menu wording of an interval.
    static func label(_ hours: Int) -> String {
        switch hours {
        case 0: return String(localized: "Aus")
        case 1: return String(localized: "Jede Stunde")
        default: return String(localized: "Alle \(hours) Stunden")
        }
    }
}

/// What the menu bar popover may say about the automatic fetch. The failure
/// detail can name a bank or an account, so the popover shows it only while
/// nothing is hidden (`MenuBarSummary.Visibility.visible`).
struct AutoSyncStatus: Equatable {
    var lastRun: Date?
    var failureDetail: String?
    var failed: Bool { failureDetail != nil }

    /// Notice lines for the popover; empty when there is nothing to say. Locked:
    /// only that the fetch is paused. Private: only that and when, no detail.
    func notice(_ visibility: MenuBarSummary.Visibility, intervalOn: Bool) -> [String] {
        switch visibility {
        case .locked:
            return intervalOn ? [String(localized: "Automatischer Abruf pausiert, bis der Tresor entsperrt ist.")] : []
        case .covered:
            return failed ? [String(localized: "Der letzte automatische Abruf ist fehlgeschlagen.")] : []
        case .visible:
            guard let detail = failureDetail else { return [] }
            return [String(localized: "Der letzte automatische Abruf ist fehlgeschlagen: \(detail)")]
        }
    }
}
