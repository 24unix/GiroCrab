import Foundation

/// When automatic sync writes this device's snapshot and looks at the
/// others'. Driven by a 5-second tick with the vault's change counter:
/// a local change is written once it has been quiet for one tick (so a
/// fetch's many inserts go out as one write), and the folder is polled
/// every 30 seconds. Changes made by a merge reset the baseline, so a merge
/// never causes a write and two devices can't keep answering each other.
struct AutoSyncState {
    enum Action: Equatable { case write, poll }

    static let pollInterval: TimeInterval = 30

    private var baseline: UInt64?
    private var previous: UInt64?
    private var lastPoll: Date?

    mutating func tick(changeCount: UInt64, now: Date) -> [Action] {
        var actions: [Action] = []
        if baseline == nil { baseline = changeCount }
        if changeCount != baseline, changeCount == previous {
            actions.append(.write)
        }
        previous = changeCount
        if lastPoll.map({ now.timeIntervalSince($0) >= Self.pollInterval }) ?? true {
            lastPoll = now
            actions.append(.poll)
        }
        return actions
    }

    mutating func merged(changeCount: UInt64) {
        // A local change still waiting to be written stays pending; the
        // write then carries the merged rows too, which costs nothing.
        if !hasPendingWrite { baseline = changeCount }
        previous = changeCount
    }

    mutating func wrote(changeCount: UInt64) {
        baseline = changeCount
    }

    /// A local change that hasn't been written yet.
    var hasPendingWrite: Bool {
        guard let baseline, let previous else { return false }
        return previous != baseline
    }

    /// Polls on the next tick (e.g. when the app comes to the front).
    mutating func pollSoon() {
        lastPoll = nil
    }
}
