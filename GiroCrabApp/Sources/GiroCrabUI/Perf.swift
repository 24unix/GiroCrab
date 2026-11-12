import os

/// Signposts for Instruments (Points of Interest track): where a reload spends
/// its time. Free when no instrument records.
enum Perf {
    static let signposter = OSSignposter(subsystem: "GiroCrab", category: .pointsOfInterest)

    @discardableResult
    static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try body()
    }
}
