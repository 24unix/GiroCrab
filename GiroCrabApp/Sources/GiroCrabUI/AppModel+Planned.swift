import Foundation
import GiroCrabCore

/// How far ahead „Geplant“ looks.
enum PlannedHorizon: String, CaseIterable, Identifiable {
    case days30, days90, year1, all
    var id: String { rawValue }

    var title: String {
        switch self {
        case .days30: String(localized: "30 Tage")
        case .days90: String(localized: "3 Monate")
        case .year1: String(localized: "12 Monate")
        case .all: String(localized: "Alles")
        }
    }

    /// Last day (`YYYY-MM-DD`) or nil for no limit.
    var endISO: String? {
        let days: Int
        switch self {
        case .days30: days = 30
        case .days90: days = 90
        case .year1: days = 365
        case .all: return nil
        }
        return Calendar.current.date(byAdding: .day, value: days, to: Date()).map(DateText.iso)
    }
}

extension AppModel {
    // MARK: - „Geplant“ (GitHub #240)

    /// Reloads the list and the sums for the current filters. Core work runs
    /// off the main thread; a result of a swapped vault or of an older filter
    /// state is dropped.
    func reloadPlanned() async {
        let accounts = plannedAccountFilter.map { [$0] } ?? []
        let to = plannedHorizon.endISO
        let version = plannedVersion
        let account = plannedAccountFilter
        let horizon = plannedHorizon
        guard let result = try? await vaultOffMain({ v in
            (try v.listPlannedPayments(from: nil, to: to, accountIds: accounts),
             try v.plannedPaymentTotals(from: nil, to: to, accountIds: accounts))
        }) else { return }
        guard account == plannedAccountFilter, horizon == plannedHorizon, version == plannedVersion else { return }
        plannedPayments = result.0
        plannedTotals = result.1
        if let id = selectedPlannedID, !result.0.contains(where: { $0.id == id }) { selectedPlannedID = nil }
    }

    /// ↑/↓ in the list: the neighbour of the selected payment (the first one
    /// when nothing is selected); stops at both ends like the booking list.
    func movePlannedSelection(_ delta: Int) {
        guard !plannedPayments.isEmpty else { return }
        let idx = selectedPlannedID.flatMap { id in plannedPayments.firstIndex { $0.id == id } } ?? -1
        selectedPlannedID = plannedPayments[max(0, min(plannedPayments.count - 1, idx + delta))].id
    }
}
