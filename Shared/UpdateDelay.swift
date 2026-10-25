//
//  UpdateDelay.swift
//  patcher
//
//  Holds back a newly released version until it has been the newest available
//  version for a configured number of days (UpdateDelayDays / UpdateDelayOverrides).
//  A newer release during the wait restarts the clock. UpdateDelayMaxDays caps the
//  total wait so labels that release more often than the delay still get patched.
//
//  The clock comes from the label's history.json: each updateFound event records
//  when a given availableVersion was first seen for a given installedVersion.
//  A held update is written to the discovered plist as UpdateStatus "delayed", so
//  staging, apply and the pending counts skip it until a later check releases it.
//

import Foundation

enum UpdateDelay {

    /// Absorbs drift between check runs, so a 1-day delay checked every 24 h releases
    /// on the next day's check rather than the one after.
    static let gracePeriod: TimeInterval = 2 * 60 * 60

    struct Hold {
        /// The delay that applies to this label.
        let delayDays: Int
        /// When the available version was first seen.
        let versionFirstSeen: Date
        /// When the available version becomes eligible to stage and apply.
        let eligibleDate: Date
    }

    // MARK: Configuration

    /// The delay in days that applies to `label`: an exact override, else the first matching
    /// wildcard override, else `UpdateDelayDays`.
    static func delayDays(for label: String, prefs: Preferences) -> Int {
        let overrides = prefs.updateDelayOverrides
        if let exact = overrides.first(where: { $0.pattern.caseInsensitiveCompare(label) == .orderedSame }) {
            return exact.days
        }
        if let wildcard = overrides.first(where: { NSPredicate(format: "self LIKE[c] %@", $0.pattern).evaluate(with: label) }) {
            return wildcard.days
        }
        return prefs.updateDelayDays
    }

    // MARK: Evaluation

    /// Returns a `Hold` when the update from `installedVersion` to `availableVersion` should be
    /// held back, or nil when it may proceed (no delay configured, delay elapsed, max wait reached,
    /// or no history to measure from).
    static func hold(label: String,
                     installedVersion: String,
                     availableVersion: String,
                     history: LabelHistory?,
                     prefs: Preferences,
                     now: Date = Date()) -> Hold? {
        let days = delayDays(for: label, prefs: prefs)
        guard days > 0, !availableVersion.isEmpty, let history else { return nil }

        let found = history.events.filter { $0.type == LabelHistoryEvent.EventType.updateFound }
        // Events recorded while this version was installed. Falls back to every updateFound
        // event when none match (e.g. the installed version changed outside of Patcher).
        let sameInstalled = found.filter { $0.installedVersion == installedVersion }
        let relevant = sameInstalled.isEmpty ? found : sameInstalled

        // Earliest sighting of this version, so a release that is pulled and then returns to an
        // earlier version keeps that version's original clock.
        guard let versionFirstSeen = relevant
                .filter({ $0.availableVersion == availableVersion })
                .map(\.date).min()
        else { return nil }

        var eligibleDate = versionFirstSeen.addingTimeInterval(TimeInterval(days) * 86_400)
        let maxDays = prefs.updateDelayMaxDays
        if maxDays > 0, let outOfDateSince = relevant.map(\.date).min() {
            eligibleDate = min(eligibleDate, outOfDateSince.addingTimeInterval(TimeInterval(maxDays) * 86_400))
        }
        guard now < eligibleDate.addingTimeInterval(-gracePeriod) else { return nil }

        return Hold(delayDays: days, versionFirstSeen: versionFirstSeen, eligibleDate: eligibleDate)
    }
}
