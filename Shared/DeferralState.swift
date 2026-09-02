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

/// Distinguishes how a deferral was initiated.
enum DeferralKind {
    /// The user actively clicked "Defer" in the prompt.
    case user
    /// The prompt's countdown timer expired without the user choosing.
    case timedOut
}

struct DeferralState: Codable {

    /// Expiry of the most recently recorded deferral. nil = no active deferral.
    var expiryDate: Date?

    /// Running total of deferrals recorded in the current apply cycle
    /// (user-initiated + timed-out + blocking-process + any other source).
    /// Reset to 0 when the deferral is cleared after a successful apply.
    var count: Int = 0

    /// Deferrals in the current apply cycle where the user actively clicked "Defer".
    var userDeferralCount: Int = 0

    /// Deferrals in the current apply cycle where the prompt's countdown timer
    /// expired without the user making a choice.
    var timedOutDeferralCount: Int = 0

    /// Deferrals in the current apply cycle caused by a label being skipped because
    /// its blocking process was still running (the user never saw a prompt).
    var blockingProcessDeferralCount: Int = 0

    private static let stateURL: URL = AppConstants.patcherConfigFolderURL
        .appendingPathComponent("deferral_state.json")

    // MARK: Codable

    init() {}

    private enum CodingKeys: String, CodingKey {
        case expiryDate, count, userDeferralCount, timedOutDeferralCount, blockingProcessDeferralCount
    }

    /// Lenient decoder — the split counters were added later, so state files
    /// written by earlier versions won't contain them.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        expiryDate                   = try c.decodeIfPresent(Date.self, forKey: .expiryDate)
        count                        = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
        userDeferralCount            = try c.decodeIfPresent(Int.self, forKey: .userDeferralCount) ?? 0
        timedOutDeferralCount        = try c.decodeIfPresent(Int.self, forKey: .timedOutDeferralCount) ?? 0
        blockingProcessDeferralCount = try c.decodeIfPresent(Int.self, forKey: .blockingProcessDeferralCount) ?? 0
    }

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

    /// Deferrals in the current apply cycle that happened without the user actively
    /// choosing — prompt-timer time-outs plus blocking-process skips.
    var automatedDeferralCount: Int {
        timedOutDeferralCount + blockingProcessDeferralCount
    }

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

    /// Records a new deferral for `minutes` from `now`, incrementing the total
    /// count and the counter for the given `kind`.
    mutating func recordDeferral(minutes: Int, kind: DeferralKind = .user, now: Date = Date()) {
        expiryDate = now.addingTimeInterval(TimeInterval(minutes * 60))
        count += 1
        switch kind {
        case .user:     userDeferralCount += 1
        case .timedOut: timedOutDeferralCount += 1
        }
    }

    /// Records an automatic Focus/DND deferral for `minutes` from `now`.
    /// Does NOT increment the count — this is system-initiated, not user-initiated.
    mutating func recordFocusDeferral(minutes: Int, now: Date = Date()) {
        expiryDate = now.addingTimeInterval(TimeInterval(minutes * 60))
    }

    /// Records a blocking-process skip — a label was skipped during apply because its
    /// blocking process was still running. Bumps the total and blocking-process
    /// counters but does NOT set an expiry: the skip is retried on the next apply
    /// cycle, not after a timer.
    mutating func recordBlockingProcessSkip() {
        count += 1
        blockingProcessDeferralCount += 1
    }

    /// Clears any active deferral and resets the count (call after successful apply).
    mutating func reset() {
        expiryDate                   = nil
        count                        = 0
        userDeferralCount            = 0
        timedOutDeferralCount        = 0
        blockingProcessDeferralCount = 0
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
