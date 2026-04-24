//
//  DeferralState.swift
//  patcher
//
//  Persistent deferral state shared between patcher and patcherscheduler.
//  Records when the user last deferred an apply cycle and when that deferral
//  expires.  Both binaries read and write this file so they share a consistent
//  view — patcher writes after the user clicks Defer; the scheduler reads
//  before deciding whether to launch patcher apply.
//

import Foundation

struct DeferralState: Codable {

    /// Expiry of the most recently recorded deferral. nil = no active deferral.
    var expiryDate: Date?

    /// Running total of deferrals recorded in the current apply cycle.
    /// Reset to 0 when the deferral is cleared after a successful apply.
    var count: Int = 0

    private static let stateURL: URL = AppConstants.patcherConfigFolderURL
        .appendingPathComponent("deferral_state.json")

    // MARK: Persistence

    static func load() -> DeferralState {
        guard let data = try? Data(contentsOf: stateURL) else { return DeferralState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(DeferralState.self, from: data)) ?? DeferralState()
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting     = .prettyPrinted
        guard let data = try? encoder.encode(self) else {
            Logger.log("❌ DeferralState: encode failed")
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: DeferralState.stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: DeferralState.stateURL, options: .atomic)
        } catch {
            Logger.log("❌ DeferralState: save failed — \(error)")
        }
    }

    // MARK: Queries

    /// True when there is an unexpired deferral.
    func isActive(now: Date = Date()) -> Bool {
        guard let expiry = expiryDate else { return false }
        return now < expiry
    }

    /// Remaining deferral time in whole minutes (0 when expired or no deferral).
    func remainingMinutes(now: Date = Date()) -> Int {
        guard let expiry = expiryDate, now < expiry else { return 0 }
        return max(1, Int(expiry.timeIntervalSince(now) / 60))
    }

    // MARK: Mutations

    /// Records a new deferral for `minutes` from `now`, incrementing the count.
    mutating func recordDeferral(minutes: Int, now: Date = Date()) {
        expiryDate = now.addingTimeInterval(TimeInterval(minutes * 60))
        count += 1
    }

    /// Records an automatic Focus/DND deferral for `minutes` from `now`.
    /// Does NOT increment the count — this is system-initiated, not user-initiated.
    mutating func recordFocusDeferral(minutes: Int, now: Date = Date()) {
        expiryDate = now.addingTimeInterval(TimeInterval(minutes * 60))
    }

    /// Clears any active deferral and resets the count (call after successful apply).
    mutating func reset() {
        expiryDate = nil
        count      = 0
    }
}


// MARK: - Duration formatting

/// Returns a human-readable description of a duration in minutes.
/// Examples:  "30 minutes",  "1 hour",  "2 hours",  "1 hour 30 minutes"
func formatDeferralDuration(_ minutes: Int) -> String {
    guard minutes > 0 else { return "0 minutes" }
    if minutes < 60 {
        return "\(minutes) minute\(minutes == 1 ? "" : "s")"
    }
    let hours = minutes / 60
    let rem   = minutes % 60
    let h     = "\(hours) hour\(hours == 1 ? "" : "s")"
    guard rem > 0 else { return h }
    return "\(h) \(rem) minute\(rem == 1 ? "" : "s")"
}
