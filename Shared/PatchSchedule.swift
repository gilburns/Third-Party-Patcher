//
//  PatchSchedule.swift
//
//  Authoritative patch-day and deadline calculations shared between
//  patcherscheduler (scheduling engine) and PatcherMenu (display).
//  Any change to scheduling logic belongs here so both targets stay in sync.
//

import Foundation

struct PatchSchedule {

    let prefs: Preferences

    // MARK: - Monthly patch day

    /// The configured patch day for the month containing `date`.
    /// Returns nil if the calendar cannot resolve the weekday/ordinal combination.
    func monthlyTargetDate(for date: Date) -> Date? {
        var cal = Calendar.current
        cal.locale = Locale(identifier: "en_US_POSIX")
        var comps = cal.dateComponents([.year, .month], from: date)
        comps.weekday        = prefs.patchingWeekday
        comps.weekdayOrdinal = prefs.patchingWeekOfMonth
        return cal.date(from: comps)
    }

    /// The next upcoming patch day on or after `now`.
    func nextPatchDay(after now: Date = Date()) -> Date? {
        var cal = Calendar.current
        cal.locale = Locale(identifier: "en_US_POSIX")
        let y = cal.component(.year,  from: now)
        let m = cal.component(.month, from: now)
        for offset in 0...1 {
            var mo = m + offset, yr = y
            if mo > 12 { mo -= 12; yr += 1 }
            var c = DateComponents()
            c.year = yr; c.month = mo
            c.weekday        = prefs.patchingWeekday
            c.weekdayOrdinal = prefs.patchingWeekOfMonth
            if let d = cal.date(from: c), d >= now { return d }
        }
        return nil
    }

    // MARK: - Deadline reference

    /// The date from which deadlines are measured.
    ///
    /// Monthly mode: this month's configured patch day — but only after it has passed.
    ///   If the patch day is still in the future there is no active deadline yet → returns nil.
    /// Deadline mode: `firstPendingDate` (when staged updates first appeared).
    ///
    /// Returns nil when there are no pending updates or no active deadline.
    func deadlineReference(firstPendingDate: Date?, now: Date = Date()) -> Date? {
        guard firstPendingDate != nil else { return nil }
        if prefs.monthlyPatchingCadenceEnabled {
            guard let target = monthlyTargetDate(for: now), target <= now else { return nil }
            return target
        } else {
            return firstPendingDate
        }
    }

    // MARK: - Days pending

    /// Days elapsed since the deadline reference.
    /// Used for Focus and hard deadline threshold comparisons.
    /// Returns 0 when there is no active deadline reference.
    func daysPendingForDeadline(firstPendingDate: Date?, now: Date = Date()) -> Int {
        guard let ref = deadlineReference(firstPendingDate: firstPendingDate, now: now) else { return 0 }
        return Calendar.current.dateComponents([.day], from: ref, to: now).day ?? 0
    }

    // MARK: - Deadline dates

    func hardDeadlineDate(firstPendingDate: Date?, now: Date = Date()) -> Date? {
        let days = prefs.deadlineDaysHard
        guard days > 0 else { return nil }
        return deadlineReference(firstPendingDate: firstPendingDate, now: now).flatMap {
            Calendar.current.date(byAdding: .day, value: days, to: $0)
        }
    }

    func focusDeadlineDate(firstPendingDate: Date?, now: Date = Date()) -> Date? {
        let days = prefs.deadlineDaysFocus
        guard days > 0 else { return nil }
        return deadlineReference(firstPendingDate: firstPendingDate, now: now).flatMap {
            Calendar.current.date(byAdding: .day, value: days, to: $0)
        }
    }

    // MARK: - Deadline reached predicates

    func isFocusDeadlineReached(firstPendingDate: Date?, now: Date = Date()) -> Bool {
        let limit = prefs.deadlineDaysFocus
        guard limit > 0 else { return false }
        return daysPendingForDeadline(firstPendingDate: firstPendingDate, now: now) >= limit
    }

    func isHardDeadlineReached(firstPendingDate: Date?, now: Date = Date()) -> Bool {
        let limit = prefs.deadlineDaysHard
        guard limit > 0 else { return false }
        return daysPendingForDeadline(firstPendingDate: firstPendingDate, now: now) >= limit
    }

    // MARK: - Aggressive patch-day deferral options

    /// Returns the deferral time options (in minutes) available at `now`.
    ///
    /// When `AggressivePatchDayDeferral` is true and today is a deadline day
    /// (patch day in monthly mode; hard deadline day in deadline mode), the
    /// options are capped based on time remaining in the patching window:
    ///
    ///   > 6 h remaining   → max 120 min
    ///   3–6 h remaining   → max  60 min
    ///   1–3 h remaining   → max  30 min
    ///  30–60 min remaining → max  15 min
    ///   1–30 min remaining → max   5 min
    ///   Past window        → [] (no deferral — force apply)
    ///
    /// If the admin's configured options are all longer than the cap, a single
    /// 5-minute option is synthesised so the user always has one short choice
    /// before time runs out.
    ///
    /// `daysPending` is the value already computed by the caller (monthly: days
    /// since patch day; deadline: age of oldest staged update).
    func allowedDeferralMinutes(now: Date = Date(), daysPending: Int) -> [Int] {
        let parsed = prefs.deferralTimerMenu
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 > 0 }
            .sorted()

        guard prefs.aggressivePatchDayDeferral else { return parsed }
        guard isDeadlineDay(now: now, daysPending: daysPending) else { return parsed }

        let remaining = minutesRemainingInWindow(now: now)
        let cap = patchDayDeferralCap(minutesRemaining: remaining)

        guard cap > 0 else { return [] }

        let filtered = parsed.filter { $0 <= cap }
        return filtered.isEmpty ? [min(5, cap)] : filtered
    }

    /// True when today is a day on which deferral pressure should be applied.
    private func isDeadlineDay(now: Date, daysPending: Int) -> Bool {
        var cal = Calendar.current
        cal.locale = Locale(identifier: "en_US_POSIX")
        if prefs.monthlyPatchingCadenceEnabled {
            guard let target = monthlyTargetDate(for: now) else { return false }
            return cal.isDate(now, inSameDayAs: target)
        } else {
            let limit = prefs.deadlineDaysHard
            return limit > 0 && daysPending >= limit
        }
    }

    /// Minutes remaining until the end of the configured patching window today.
    /// Falls back to end-of-day (23:59) when `PatchingEndTime` is not set.
    private func minutesRemainingInWindow(now: Date) -> Int {
        var cal = Calendar.current
        cal.locale = Locale(identifier: "en_US_POSIX")
        var comps = cal.dateComponents([.year, .month, .day], from: now)

        let endTime = prefs.patchingEndTime
        if endTime.isEmpty {
            comps.hour = 23; comps.minute = 59
        } else {
            let parts = endTime.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else { return 8 * 60 }
            comps.hour = parts[0]; comps.minute = parts[1]
        }

        guard let windowEnd = cal.date(from: comps) else { return 0 }
        return max(0, Int(windowEnd.timeIntervalSince(now) / 60))
    }

    /// Maximum deferral (in minutes) based on how many minutes remain in the window.
    private func patchDayDeferralCap(minutesRemaining: Int) -> Int {
        switch minutesRemaining {
        case 361...:   return 120   // > 6 h   → cap 2 h
        case 181...360: return 60   // 3–6 h   → cap 1 h
        case 61...180:  return 30   // 1–3 h   → cap 30 m
        case 31...60:   return 15   // 30–60 m → cap 15 m
        case 1...30:    return 5    // < 30 m  → cap 5 m
        default:        return 0    // past window → force apply
        }
    }
}
