//
//  SchedulerStateSnapshot.swift
//  patcherreport
//
//  Read-only view of the daemon's scheduler_state.json.  The authoritative
//  `SchedulerState` type lives in the patcherscheduler target; patcherreport only
//  needs a couple of fields for deadline math, so it decodes them directly rather
//  than pulling in the whole type.
//

import Foundation

struct SchedulerStateSnapshot {
    /// When staged updates first appeared and started the deadline clock.
    /// Cleared by the scheduler once every staged update has been applied.
    let firstPendingDate: Date?
    /// Timestamp of the last apply run recorded by the scheduler.
    let lastApplyDate: Date?

    static let empty = SchedulerStateSnapshot(firstPendingDate: nil, lastApplyDate: nil)

    static func load() -> SchedulerStateSnapshot {
        let url = AppConstants.patcherConfigFolderURL
            .appendingPathComponent("scheduler_state.json")
        guard let data = try? Data(contentsOf: url),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .empty }

        // SchedulerState.save() encodes dates with JSONEncoder's .iso8601 strategy.
        let iso = ISO8601DateFormatter()
        func date(_ key: String) -> Date? {
            (obj[key] as? String).flatMap { iso.date(from: $0) }
        }
        return SchedulerStateSnapshot(
            firstPendingDate: date("firstPendingDate"),
            lastApplyDate:    date("lastApplyDate")
        )
    }
}
