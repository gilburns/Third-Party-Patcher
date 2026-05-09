//
//  SchedulerState.swift
//  patcher
//
//  Created by Gil Burns on 4/15/26.
//

import Foundation


// MARK: - Apply schedule

struct ApplySchedule {
    let focusDeadlineReached: Bool  // bypass Focus/DND
    let hardDeadlineReached:  Bool  // force install, ignore deferral

    init(focusDeadlineReached: Bool = false, hardDeadlineReached: Bool = false) {
        self.focusDeadlineReached = focusDeadlineReached
        self.hardDeadlineReached  = hardDeadlineReached
    }
}

// MARK: - Persistent scheduler state
struct SchedulerState: Codable {

    // Deployment
    var firstLaunchDate: Date?
    var initialScanDelaySeconds: Int?

    // Per-subcommand last-run timestamps
    var lastScanDate: Date?
    var lastLightScanDate: Date?
    var lastCheckDate: Date?
    var lastStageDate: Date?
    var lastApplyDate: Date?

    // Installomator version recorded at last scan (for label-update trigger)
    var installomatorVersionAtLastScan: String?

    // Pending update tracking (for deadline-based apply scheduling)
    var firstPendingDate: Date?
    var deferralCount: Int = 0

    // Webhook report tracking
    var lastWebhookReportDate: Date?

    private static let url = AppConstants.patcherConfigFolderURL
        .appendingPathComponent("scheduler_state.json")

    static func load() -> SchedulerState {
        guard let data = try? Data(contentsOf: url) else { return SchedulerState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(SchedulerState.self, from: data) else {
            Logger.log("⚠️ SchedulerState: failed to decode state file — starting fresh.")
            return SchedulerState()
        }
        return state
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(self) else {
            Logger.log("❌ SchedulerState: failed to encode state")
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: AppConstants.patcherConfigFolderURL,
                withIntermediateDirectories: true
            )
            try data.write(to: SchedulerState.url, options: .atomic)
        } catch {
            Logger.log("❌ SchedulerState: failed to save — \(error)")
        }
    }
}
