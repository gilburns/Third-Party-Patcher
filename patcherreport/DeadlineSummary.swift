//
//  DeadlineSummary.swift
//  patcherreport
//
//  Deadline math for the summary and pending reports.  Mirrors the calculations
//  the daemon performs in `PatchSchedule` so admins (and Jamf Extension
//  Attributes) can see how close a device is to its Focus / hard deadline.
//

import Foundation

struct DeadlineSummary {

    /// "monthly" when MonthlyPatchingCadenceEnabled, otherwise "deadline".
    let patchingMode: String

    /// Number of staged-but-not-applied updates.
    let pendingCount: Int

    /// Earliest `stagedTimestamp` among the pending updates.
    let oldestPendingDate: Date?
    /// Whole calendar days since `oldestPendingDate` (0 when nothing is pending).
    let oldestPendingDays: Int

    /// The date deadlines are measured from: the scheduler's firstPendingDate in
    /// deadline mode, or this month's patch day (once passed) in monthly mode.
    /// nil when nothing is pending, or in monthly mode before patch day.
    let deadlineReferenceDate: Date?
    /// Whole days elapsed since `deadlineReferenceDate` (0 when there is none).
    let daysPendingForDeadline: Int

    /// Configured thresholds (0 = disabled).
    let deadlineDaysFocus: Int
    let deadlineDaysHard: Int

    /// Absolute dates the thresholds are reached. nil when the threshold is
    /// disabled or there is no active deadline reference.
    let focusDeadlineDate: Date?
    let hardDeadlineDate: Date?

    /// Whole days from now until each deadline (negative once passed).
    /// nil when the corresponding date is nil.
    let daysUntilFocusDeadline: Int?
    let daysUntilHardDeadline: Int?

    /// Whether each threshold has already been reached.
    let focusDeadlineReached: Bool
    let hardDeadlineReached: Bool

    // MARK: - Build

    init(_ ctx: ReportContext, pendingItems: [PendingItem]) {
        let now      = ctx.now
        let prefs    = ctx.prefs
        let schedule = PatchSchedule(prefs: prefs)
        let cal      = Calendar.current

        patchingMode = prefs.monthlyPatchingCadenceEnabled ? "monthly" : "deadline"
        pendingCount = pendingItems.count

        let oldest = pendingItems.map(\.stagedDate).min()
        oldestPendingDate = oldest
        oldestPendingDays = oldest.map { cal.dateComponents([.day], from: $0, to: now).day ?? 0 } ?? 0

        // The scheduler's firstPendingDate is authoritative; fall back to the
        // oldest staged timestamp (the same fallback the patcher itself uses).
        let firstPending = ctx.schedulerState.firstPendingDate ?? oldest

        deadlineReferenceDate  = schedule.deadlineReference(firstPendingDate: firstPending, now: now)
        daysPendingForDeadline = schedule.daysPendingForDeadline(firstPendingDate: firstPending, now: now)

        deadlineDaysFocus = prefs.deadlineDaysFocus
        deadlineDaysHard  = prefs.deadlineDaysHard

        let focusDate = schedule.focusDeadlineDate(firstPendingDate: firstPending, now: now)
        let hardDate  = schedule.hardDeadlineDate(firstPendingDate: firstPending, now: now)
        focusDeadlineDate = focusDate
        hardDeadlineDate  = hardDate

        daysUntilFocusDeadline = focusDate.map { cal.dateComponents([.day], from: now, to: $0).day ?? 0 }
        daysUntilHardDeadline  = hardDate.map  { cal.dateComponents([.day], from: now, to: $0).day ?? 0 }

        focusDeadlineReached = schedule.isFocusDeadlineReached(firstPendingDate: firstPending, now: now)
        hardDeadlineReached  = schedule.isHardDeadlineReached(firstPendingDate: firstPending, now: now)
    }

    // MARK: - Serialisation

    /// Nested dictionary used by the `summary` / `pending` JSON payloads and by `get`.
    func jsonObject() -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var d: [String: Any] = [
            "patchingMode":           patchingMode,
            "pendingCount":           pendingCount,
            "oldestPendingDays":      oldestPendingDays,
            "daysPendingForDeadline": daysPendingForDeadline,
            "deadlineDaysFocus":      deadlineDaysFocus,
            "deadlineDaysHard":       deadlineDaysHard,
            "focusDeadlineReached":   focusDeadlineReached,
            "hardDeadlineReached":    hardDeadlineReached,
        ]
        if let v = oldestPendingDate      { d["oldestPendingDate"]      = iso.string(from: v) }
        if let v = deadlineReferenceDate  { d["deadlineReferenceDate"]  = iso.string(from: v) }
        if let v = focusDeadlineDate      { d["focusDeadlineDate"]      = iso.string(from: v) }
        if let v = hardDeadlineDate       { d["hardDeadlineDate"]       = iso.string(from: v) }
        if let v = daysUntilFocusDeadline { d["daysUntilFocusDeadline"] = v }
        if let v = daysUntilHardDeadline  { d["daysUntilHardDeadline"]  = v }
        return d
    }

    /// Rows for the `summary` / `pending` CSV payloads (metric,value form).
    func csvRows() -> [[String]] {
        let iso = ISO8601DateFormatter()
        let rows: [[String]] = [
            ["patchingMode",           patchingMode],
            ["pendingCount",           "\(pendingCount)"],
            ["oldestPendingDate",      oldestPendingDate.map { iso.string(from: $0) } ?? ""],
            ["oldestPendingDays",      "\(oldestPendingDays)"],
            ["deadlineReferenceDate",  deadlineReferenceDate.map { iso.string(from: $0) } ?? ""],
            ["daysPendingForDeadline", "\(daysPendingForDeadline)"],
            ["deadlineDaysFocus",      "\(deadlineDaysFocus)"],
            ["deadlineDaysHard",       "\(deadlineDaysHard)"],
            ["focusDeadlineDate",      focusDeadlineDate.map { iso.string(from: $0) } ?? ""],
            ["hardDeadlineDate",       hardDeadlineDate.map { iso.string(from: $0) } ?? ""],
            ["daysUntilFocusDeadline", daysUntilFocusDeadline.map { "\($0)" } ?? ""],
            ["daysUntilHardDeadline",  daysUntilHardDeadline.map { "\($0)" } ?? ""],
            ["focusDeadlineReached",   "\(focusDeadlineReached)"],
            ["hardDeadlineReached",    "\(hardDeadlineReached)"],
        ]
        return rows
    }

    /// Lines for the human-readable table reports.
    func tableLines() -> [String] {
        var lines: [String] = []
        func line(_ label: String, _ value: String) -> String { " \(col(label, 34)) \(value)" }

        lines.append(line("Patching mode:", patchingMode))
        if pendingCount == 0 {
            lines.append(line("Pending updates:", "none — no active deadline"))
            return lines
        }

        if let oldest = oldestPendingDate {
            lines.append(line("Oldest pending update:", "\(shortDate(oldest))  (\(oldestPendingDays)d ago)"))
        }
        if let ref = deadlineReferenceDate {
            lines.append(line("Deadline measured from:", "\(shortDate(ref))  (\(daysPendingForDeadline)d elapsed)"))
        } else if patchingMode == "monthly" {
            lines.append(line("Deadline measured from:", "patch day not yet reached"))
        }

        func deadlineLine(_ label: String, days: Int, date: Date?, until: Int?, reached: Bool) -> String {
            guard days > 0 else { return line(label, "disabled") }
            guard let date, let until else { return line(label, "\(days)d threshold — not yet started") }
            if reached { return line(label, "REACHED — \(shortDate(date))") }
            return line(label, "\(shortDate(date))  (in \(until)d)")
        }
        lines.append(deadlineLine("Focus deadline:", days: deadlineDaysFocus,
                                  date: focusDeadlineDate, until: daysUntilFocusDeadline,
                                  reached: focusDeadlineReached))
        lines.append(deadlineLine("Hard deadline:", days: deadlineDaysHard,
                                  date: hardDeadlineDate, until: daysUntilHardDeadline,
                                  reached: hardDeadlineReached))
        return lines
    }
}
