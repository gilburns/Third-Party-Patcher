//
//  patcherschedulerTests.swift
//  patcherschedulerTests
//
//  Tests for pure scheduling logic — no process launching, no disk I/O.
//

import Testing
import Foundation

// MARK: - Test environment sanity check

struct EnvironmentSanityTests {

    @Test func requiredEnvironmentVariablesAreSet() {
        let env = ProcessInfo.processInfo.environment
        let dataDir = env["PATCHER_DATA_DIR"]
        let logDir  = env["PATCHER_LOG_DIR"]

        // Print the full environment so it appears in the test log on failure
        let relevant = env.filter { $0.key.hasPrefix("PATCHER") }
        print("PATCHER_* environment variables visible to this test process:")
        if relevant.isEmpty {
            print("  (none found)")
        } else {
            relevant.sorted(by: { $0.key < $1.key }).forEach { print("  \($0.key) = \($0.value)") }
        }

        #expect(dataDir != nil, "PATCHER_DATA_DIR is not set — add it to the test scheme environment variables")
        #expect(logDir  != nil, "PATCHER_LOG_DIR is not set — add it to the test scheme environment variables")
    }
}


// MARK: - DeferralState

struct DeferralStateTests {

    @Test func notActiveWhenFresh() {
        #expect(!DeferralState().isActive())
    }

    @Test func activeWhenExpiryInFuture() {
        var state = DeferralState()
        let now = Date()
        state.recordDeferral(minutes: 60, now: now)
        #expect(state.isActive(now: now.addingTimeInterval(30 * 60)))
    }

    @Test func notActiveAtExactExpiry() {
        var state = DeferralState()
        let now = Date()
        state.recordDeferral(minutes: 60, now: now)
        let expiry = now.addingTimeInterval(60 * 60)
        // isActive uses `now < expiry`, so at the exact expiry second it is no longer active
        #expect(!state.isActive(now: expiry))
    }

    @Test func notActiveAfterExpiry() {
        var state = DeferralState()
        let now = Date()
        state.recordDeferral(minutes: 60, now: now)
        #expect(!state.isActive(now: now.addingTimeInterval(90 * 60)))
    }

    @Test func remainingMinutesCorrect() {
        var state = DeferralState()
        let now = Date()
        state.recordDeferral(minutes: 120, now: now)
        #expect(state.remainingMinutes(now: now.addingTimeInterval(30 * 60)) == 90)
    }

    @Test func remainingMinutesZeroWhenExpired() {
        var state = DeferralState()
        state.recordDeferral(minutes: 30, now: Date.distantPast)
        #expect(state.remainingMinutes() == 0)
    }

    @Test func remainingMinutesZeroWhenFresh() {
        #expect(DeferralState().remainingMinutes() == 0)
    }

    @Test func remainingMinutesAtLeastOneWhenSecondsLeft() {
        var state = DeferralState()
        let now = Date()
        state.recordDeferral(minutes: 1, now: now)
        // 30 seconds in — function clamps to min 1
        #expect(state.remainingMinutes(now: now.addingTimeInterval(30)) == 1)
    }

    @Test func recordDeferralIncrementsCount() {
        var state = DeferralState()
        state.recordDeferral(minutes: 60)
        #expect(state.count == 1)
        state.recordDeferral(minutes: 60)
        #expect(state.count == 2)
    }

    @Test func recordDeferralSetsExpiry() {
        var state = DeferralState()
        let now = Date()
        state.recordDeferral(minutes: 90, now: now)
        let expected = now.addingTimeInterval(90 * 60)
        #expect(abs(state.expiryDate!.timeIntervalSince(expected)) < 1.0)
    }

    @Test func resetClearsExpiryAndCount() {
        var state = DeferralState()
        state.recordDeferral(minutes: 120)
        state.recordDeferral(minutes: 60)
        state.reset()
        #expect(state.expiryDate == nil)
        #expect(state.count == 0)
    }

    @Test func resetOnFreshStateIsIdempotent() {
        var state = DeferralState()
        state.reset()
        #expect(state.expiryDate == nil)
        #expect(state.count == 0)
    }

    @Test func countNotResetBySecondDeferral() {
        // count should keep accumulating — only reset() zeroes it
        var state = DeferralState()
        state.recordDeferral(minutes: 30)
        state.recordDeferral(minutes: 30)
        state.recordDeferral(minutes: 30)
        #expect(state.count == 3)
    }

    @Test func splitCountersTrackKindSeparately() {
        var state = DeferralState()
        state.recordDeferral(minutes: 30, kind: .user)
        state.recordDeferral(minutes: 30, kind: .timedOut)
        state.recordDeferral(minutes: 30, kind: .user)
        state.recordBlockingProcessSkip()
        #expect(state.count == 4)
        #expect(state.userDeferralCount == 2)
        #expect(state.timedOutDeferralCount == 1)
        #expect(state.blockingProcessDeferralCount == 1)
    }

    @Test func blockingProcessSkipDoesNotSetExpiry() {
        var state = DeferralState()
        state.recordBlockingProcessSkip()
        #expect(state.expiryDate == nil)
        #expect(!state.isActive())
        #expect(state.count == 1)
        #expect(state.blockingProcessDeferralCount == 1)
    }

    @Test func resetClearsSplitCounters() {
        var state = DeferralState()
        state.recordDeferral(minutes: 30, kind: .user)
        state.recordDeferral(minutes: 30, kind: .timedOut)
        state.recordBlockingProcessSkip()
        state.reset()
        #expect(state.userDeferralCount == 0)
        #expect(state.timedOutDeferralCount == 0)
        #expect(state.blockingProcessDeferralCount == 0)
    }

    @Test func decodesLegacyStateWithoutSplitCounters() throws {
        let json = #"{"count":2}"#.data(using: .utf8)!
        let state = try JSONDecoder().decode(DeferralState.self, from: json)
        #expect(state.count == 2)
        #expect(state.userDeferralCount == 0)
        #expect(state.timedOutDeferralCount == 0)
        #expect(state.blockingProcessDeferralCount == 0)
    }

    @Test func splitCountersRoundTripThroughJSON() throws {
        var state = DeferralState()
        state.recordDeferral(minutes: 60, kind: .user)
        state.recordDeferral(minutes: 60, kind: .timedOut)
        state.recordBlockingProcessSkip()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DeferralState.self, from: try encoder.encode(state))
        #expect(decoded.count == 3)
        #expect(decoded.userDeferralCount == 1)
        #expect(decoded.timedOutDeferralCount == 1)
        #expect(decoded.blockingProcessDeferralCount == 1)
    }
}


// MARK: - formatDeferralDuration

struct FormatDeferralDurationTests {

    @Test func zeroMinutes() {
        #expect(formatDeferralDuration(0) == "0 minutes")
    }

    @Test func oneMinute() {
        #expect(formatDeferralDuration(1) == "1 minute")
    }

    @Test func thirtyMinutes() {
        #expect(formatDeferralDuration(30) == "30 minutes")
    }

    @Test func fiftyNineMinutes() {
        #expect(formatDeferralDuration(59) == "59 minutes")
    }

    @Test func exactlyOneHour() {
        #expect(formatDeferralDuration(60) == "1 hour")
    }

    @Test func exactlyTwoHours() {
        #expect(formatDeferralDuration(120) == "2 hours")
    }

    @Test func oneHourThirtyMinutes() {
        #expect(formatDeferralDuration(90) == "1 hour 30 minutes")
    }

    @Test func twoHoursOneMinute() {
        #expect(formatDeferralDuration(121) == "2 hours 1 minute")
    }

    @Test func twentyFourHours() {
        #expect(formatDeferralDuration(1440) == "24 hours")
    }

    @Test func negativeMinutes() {
        // Negative input: guard minutes > 0 catches this — same as 0
        #expect(formatDeferralDuration(-1) == "0 minutes")
    }
}


// MARK: - PatcherScheduler: deadline-based apply schedule

struct DeadlineApplyScheduleTests {

    // Preferences() falls back to all defaults when no plist is present — safe in tests.
    let scheduler = PatcherScheduler(prefs: Preferences())

    @Test func returnsNilWhenNoPendingDate() {
        let state = SchedulerState()
        #expect(scheduler.resolveDeadlineApplySchedule(state: state, now: Date()) == nil)
    }

    @Test func returnsDueWhenNeverApplied() {
        var state = SchedulerState()
        state.firstPendingDate = Date().addingTimeInterval(-48 * 3600)
        let result = scheduler.resolveDeadlineApplySchedule(state: state, now: Date())
        #expect(result != nil)
        #expect(result?.hardDeadlineReached == false)
    }

    @Test func returnsNilWhenIntervalNotElapsed() {
        let now = Date()
        var state = SchedulerState()
        state.firstPendingDate = now.addingTimeInterval(-48 * 3600)
        state.lastApplyDate    = now.addingTimeInterval(-1 * 3600)   // 1 h ago; default interval 24 h
        #expect(scheduler.resolveDeadlineApplySchedule(state: state, now: now) == nil)
    }

    @Test func returnsDueWhenIntervalElapsed() {
        let now = Date()
        var state = SchedulerState()
        state.firstPendingDate = now.addingTimeInterval(-48 * 3600)
        state.lastApplyDate    = now.addingTimeInterval(-25 * 3600)  // 25 h ago; interval 24 h
        #expect(scheduler.resolveDeadlineApplySchedule(state: state, now: now) != nil)
    }

    @Test func hardDeadlineSetWhenExceeded() {
        let now = Date()
        var state = SchedulerState()
        // Default deadlineDaysHard = 14; use 15 days
        state.firstPendingDate = now.addingTimeInterval(-15 * 24 * 3600)
        state.lastApplyDate    = now.addingTimeInterval(-25 * 3600)
        #expect(scheduler.resolveDeadlineApplySchedule(state: state, now: now)?.hardDeadlineReached == true)
    }

    @Test func hardDeadlineNotSetBeforeLimit() {
        let now = Date()
        var state = SchedulerState()
        state.firstPendingDate = now.addingTimeInterval(-5 * 24 * 3600)
        state.lastApplyDate    = now.addingTimeInterval(-25 * 3600)
        #expect(scheduler.resolveDeadlineApplySchedule(state: state, now: now)?.hardDeadlineReached == false)
    }
}


// MARK: - PatcherScheduler: monthly apply schedule
//
// Default prefs: second Tuesday (weekday=3, weekOfMonth=2), no time window.
// April 2026 patch day: April 14 (second Tuesday).

struct MonthlyApplyScheduleTests {

    let scheduler = PatcherScheduler(prefs: Preferences())

    // Convenience: build a Date in April 2026 at a given day/hour
    private func april2026(_ day: Int, hour: Int = 12) -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = day
        comps.hour = hour; comps.minute = 0; comps.second = 0
        return Calendar.current.date(from: comps)!
    }

    @Test func returnsNilBeforePatchDay() {
        // April 13 is before the second Tuesday (April 14) — no apply yet
        var state = SchedulerState()
        state.firstPendingDate = april2026(10)
        #expect(scheduler.resolveMonthlyApplySchedule(state: state, now: april2026(13)) == nil)
    }

    @Test func returnsNonNilDayAfterPatchDay() {
        // April 15 is after the patch day and no prior apply — still due
        var state = SchedulerState()
        state.firstPendingDate = april2026(9)
        #expect(scheduler.resolveMonthlyApplySchedule(state: state, now: april2026(15)) != nil)
    }

    @Test func returnsNonNilOnPatchDay() {
        // April 14 is the second Tuesday — patch day
        var state = SchedulerState()
        state.firstPendingDate = april2026(9)
        #expect(scheduler.resolveMonthlyApplySchedule(state: state, now: april2026(14)) != nil)
    }

    @Test func returnsNilIfAlreadyAppliedToday() {
        var state = SchedulerState()
        state.firstPendingDate = april2026(9)
        state.lastApplyDate    = april2026(14, hour: 10)  // ran at 10 am same day
        #expect(scheduler.resolveMonthlyApplySchedule(state: state, now: april2026(14, hour: 14)) == nil)
    }

    @Test func returnsNonNilIfAppliedYesterday() {
        // lastApplyDate is April 13 — different day, so today's run is allowed
        var state = SchedulerState()
        state.firstPendingDate = april2026(9)
        state.lastApplyDate    = april2026(13)
        #expect(scheduler.resolveMonthlyApplySchedule(state: state, now: april2026(14)) != nil)
    }

    @Test func hardDeadlineSetWhenExceeded() {
        // Monthly mode counts from the patch day (April 14).
        // April 29 is 15 days after the patch day — exceeds default deadlineDaysHard = 14.
        var state = SchedulerState()
        state.firstPendingDate = april2026(9)
        state.lastApplyDate    = april2026(14)  // applied on patch day; interval long since elapsed
        #expect(scheduler.resolveMonthlyApplySchedule(state: state, now: april2026(29))?.hardDeadlineReached == true)
    }

    @Test func hardDeadlineNotSetBeforeLimit() {
        // April 14 is the patch day itself — 0 days since patch day, well under limit
        var state = SchedulerState()
        state.firstPendingDate = april2026(9)
        #expect(scheduler.resolveMonthlyApplySchedule(state: state, now: april2026(14))?.hardDeadlineReached == false)
    }
}


// MARK: - PatcherScheduler: isHardDeadlineReached
// Uses empty testPrefs so all values come from defaults (monthly mode off, deadlineDaysHard = 14).
// Avoids loading the real plist which may have MonthlyPatchingCadenceEnabled = true, which would
// cause daysPendingForDeadline to measure from the patch day rather than firstPendingDate.

struct HardDeadlineTests {

    let scheduler = PatcherScheduler(prefs: Preferences(testPrefs: [:]))

    @Test func falseWhenNoPendingDate() {
        #expect(!scheduler.isHardDeadlineReached(state: SchedulerState(), now: Date()))
    }

    @Test func falseWhenUnderLimit() {
        var state = SchedulerState()
        state.firstPendingDate = Date().addingTimeInterval(-5 * 24 * 3600)
        #expect(!scheduler.isHardDeadlineReached(state: state, now: Date()))
    }

    @Test func trueWhenExceeded() {
        var state = SchedulerState()
        state.firstPendingDate = Date().addingTimeInterval(-15 * 24 * 3600)
        #expect(scheduler.isHardDeadlineReached(state: state, now: Date()))
    }

    @Test func trueAtExactDeadlineDay() {
        let now = Date()
        var state = SchedulerState()
        // Exactly 14 days (default deadlineDaysHard) — should be at or past deadline
        state.firstPendingDate = now.addingTimeInterval(-14 * 24 * 3600)
        #expect(scheduler.isHardDeadlineReached(state: state, now: now))
    }
}


// MARK: - PatcherScheduler: shouldRun checks

struct ShouldRunTests {

    let scheduler = PatcherScheduler(prefs: Preferences())

    // MARK: Scan

    @Test func shouldScanWhenNeverRun() {
        #expect(scheduler.shouldRunScan(state: SchedulerState(), now: Date()))
    }

    @Test func shouldNotScanWhenRecentlyRun() {
        var state = SchedulerState()
        state.lastScanDate = Date().addingTimeInterval(-1 * 24 * 3600)   // 1 day; default interval 30 days
        // Set installomatorVersionAtLastScan to match what loadInstallomatorVersion() returns
        // in the test environment (empty string when PATCHER_DATA_DIR redirects to a temp dir
        // that has no Installomator version file). This prevents the scanOnLabelUpdate path
        // from firing and triggering an unexpected scan.
        state.installomatorVersionAtLastScan = ""
        #expect(!scheduler.shouldRunScan(state: state, now: Date()))
    }

    @Test func shouldScanWhenIntervalElapsed() {
        var state = SchedulerState()
        state.lastScanDate = Date().addingTimeInterval(-31 * 24 * 3600)  // 31 days; interval 30
        #expect(scheduler.shouldRunScan(state: state, now: Date()))
    }

    // MARK: Check

    @Test func shouldCheckWhenNeverRun() {
        #expect(scheduler.shouldRunCheck(state: SchedulerState(), now: Date()))
    }

    @Test func shouldNotCheckWhenRecentlyRun() {
        var state = SchedulerState()
        state.lastCheckDate = Date().addingTimeInterval(-1 * 3600)   // 1 h; default interval 24 h
        #expect(!scheduler.shouldRunCheck(state: state, now: Date()))
    }

    @Test func shouldCheckWhenIntervalElapsed() {
        var state = SchedulerState()
        state.lastCheckDate = Date().addingTimeInterval(-25 * 3600)  // 25 h; interval 24 h
        #expect(scheduler.shouldRunCheck(state: state, now: Date()))
    }

    // MARK: Stage

    @Test func shouldStageWhenNeverRun() {
        #expect(scheduler.shouldRunStage(state: SchedulerState(), now: Date()))
    }

    @Test func shouldNotStageWhenRecentlyRun() {
        var state = SchedulerState()
        state.lastStageDate = Date().addingTimeInterval(-1 * 3600)   // 1 h; default interval 24 h
        #expect(!scheduler.shouldRunStage(state: state, now: Date()))
    }

    @Test func shouldStageWhenIntervalElapsed() {
        var state = SchedulerState()
        state.lastStageDate = Date().addingTimeInterval(-25 * 3600)  // 25 h; interval 24 h
        #expect(scheduler.shouldRunStage(state: state, now: Date()))
    }
}


// MARK: - isWithinPatchingWindow

struct PatchingWindowTests {

    // Builds a scheduler with specific start/end time strings (HH:MM 24-hour format).
    private func scheduler(start: String, end: String) -> PatcherScheduler {
        PatcherScheduler(prefs: Preferences(testPrefs: [
            "PatchingStartTime": start,
            "PatchingEndTime":   end,
        ]))
    }

    // Builds a Date for today at a specific hour and minute.
    private func today(hour: Int, minute: Int) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour; comps.minute = minute; comps.second = 0
        return Calendar.current.date(from: comps)!
    }

    @Test func alwaysTrueWhenNoWindowConfigured() {
        // Both keys absent → defaults to "" → guard fires → always true
        let s = PatcherScheduler(prefs: Preferences(testPrefs: [:]))
        #expect(s.isWithinPatchingWindow(now: today(hour: 3, minute: 0)))
        #expect(s.isWithinPatchingWindow(now: today(hour: 23, minute: 59)))
    }

    @Test func alwaysTrueWhenOnlyStartConfigured() {
        // Only start set — end is empty → guard fires → always true
        let s = PatcherScheduler(prefs: Preferences(testPrefs: ["PatchingStartTime": "09:00"]))
        #expect(s.isWithinPatchingWindow(now: today(hour: 12, minute: 0)))
    }

    @Test func alwaysTrueWhenOnlyEndConfigured() {
        let s = PatcherScheduler(prefs: Preferences(testPrefs: ["PatchingEndTime": "17:00"]))
        #expect(s.isWithinPatchingWindow(now: today(hour: 12, minute: 0)))
    }

    @Test func trueWhenInsideWindow() {
        #expect(scheduler(start: "09:00", end: "17:00").isWithinPatchingWindow(now: today(hour: 12, minute: 0)))
    }

    @Test func trueAtWindowStartBoundary() {
        #expect(scheduler(start: "09:00", end: "17:00").isWithinPatchingWindow(now: today(hour: 9, minute: 0)))
    }

    @Test func trueAtWindowEndBoundary() {
        #expect(scheduler(start: "09:00", end: "17:00").isWithinPatchingWindow(now: today(hour: 17, minute: 0)))
    }

    @Test func falseOneMinuteBeforeStart() {
        #expect(!scheduler(start: "09:00", end: "17:00").isWithinPatchingWindow(now: today(hour: 8, minute: 59)))
    }

    @Test func falseOneMinuteAfterEnd() {
        #expect(!scheduler(start: "09:00", end: "17:00").isWithinPatchingWindow(now: today(hour: 17, minute: 1)))
    }

    @Test func falseMidnightOutsideWindow() {
        #expect(!scheduler(start: "09:00", end: "17:00").isWithinPatchingWindow(now: today(hour: 0, minute: 0)))
    }

    @Test func trueForMalformedStartTime() {
        // Malformed → toMin returns nil → guard fires → safe fallback true
        #expect(scheduler(start: "9am", end: "17:00").isWithinPatchingWindow(now: today(hour: 12, minute: 0)))
    }

    @Test func trueForMalformedEndTime() {
        #expect(scheduler(start: "09:00", end: "5pm").isWithinPatchingWindow(now: today(hour: 12, minute: 0)))
    }

    @Test func narrowWindowOneMinute() {
        // Window is exactly 12:00–12:00 (single minute)
        #expect(scheduler(start: "12:00", end: "12:00").isWithinPatchingWindow(now: today(hour: 12, minute: 0)))
        #expect(!scheduler(start: "12:00", end: "12:00").isWithinPatchingWindow(now: today(hour: 12, minute: 1)))
    }
}


// MARK: - monthlyTargetDate
//
// Calendar weekday numbers: 1=Sun 2=Mon 3=Tue 4=Wed 5=Thu 6=Fri 7=Sat
//
// Verified dates:
//   April 2026:  April 1 = Wed → 2nd Tue = April 14
//   May   2026:  May   1 = Fri → 1st Mon = May 4
//   June  2026:  June  1 = Mon → 3rd Wed = June 17

struct MonthlyTargetDateTests {

    private func scheduler(weekday: Int, weekOfMonth: Int) -> PatcherScheduler {
        PatcherScheduler(prefs: Preferences(testPrefs: [
            "PatchingWeekday":    weekday,
            "PatchingWeekOfMonth": weekOfMonth,
        ]))
    }

    private func date(year: Int, month: Int, day: Int) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = 12; comps.minute = 0; comps.second = 0
        return Calendar.current.date(from: comps)!
    }

    @Test func secondTuesdayApril2026() {
        let target = scheduler(weekday: 3, weekOfMonth: 2).monthlyTargetDate(for: date(year: 2026, month: 4, day: 1))
        #expect(target != nil)
        #expect(Calendar.current.isDate(target!, inSameDayAs: date(year: 2026, month: 4, day: 14)))
    }

    @Test func firstMondayMay2026() {
        let target = scheduler(weekday: 2, weekOfMonth: 1).monthlyTargetDate(for: date(year: 2026, month: 5, day: 1))
        #expect(target != nil)
        #expect(Calendar.current.isDate(target!, inSameDayAs: date(year: 2026, month: 5, day: 4)))
    }

    @Test func thirdWednesdayJune2026() {
        let target = scheduler(weekday: 4, weekOfMonth: 3).monthlyTargetDate(for: date(year: 2026, month: 6, day: 1))
        #expect(target != nil)
        #expect(Calendar.current.isDate(target!, inSameDayAs: date(year: 2026, month: 6, day: 17)))
    }

    @Test func targetIsAlwaysInSameMonthAndYearAsInput() {
        let s = scheduler(weekday: 3, weekOfMonth: 2)
        for month in 1...12 {
            let input  = date(year: 2026, month: month, day: 15)
            guard let target = s.monthlyTargetDate(for: input) else { continue }
            let cal = Calendar.current
            #expect(cal.component(.year,  from: target) == 2026)
            #expect(cal.component(.month, from: target) == month)
        }
    }

    @Test func targetWeekdayMatchesConfig() {
        // Whatever weekday we configure, the result should land on that weekday
        let cal = Calendar.current
        for weekday in 1...7 {
            let s = scheduler(weekday: weekday, weekOfMonth: 2)
            guard let target = s.monthlyTargetDate(for: date(year: 2026, month: 6, day: 1)) else { continue }
            #expect(cal.component(.weekday, from: target) == weekday)
        }
    }

    @Test func targetOrdinalMatchesConfig() {
        // The result should be in the Nth occurrence of that weekday
        let cal = Calendar.current
        for week in 1...4 {
            let s = scheduler(weekday: 3, weekOfMonth: week)  // Nth Tuesday
            guard let target = s.monthlyTargetDate(for: date(year: 2026, month: 4, day: 1)) else { continue }
            #expect(cal.component(.weekdayOrdinal, from: target) == week)
        }
    }
}


// MARK: - SchedulerState Codable round-trip

struct SchedulerStateCodableTests {

    @Test func roundTripPreservesAllDates() throws {
        let now = Date()
        var state = SchedulerState()
        state.firstLaunchDate            = now.addingTimeInterval(-30 * 24 * 3600)
        state.initialScanDelaySeconds    = 3600
        state.lastScanDate               = now.addingTimeInterval(-2 * 24 * 3600)
        state.lastCheckDate              = now.addingTimeInterval(-12 * 3600)
        state.lastStageDate              = now.addingTimeInterval(-6 * 3600)
        state.lastApplyDate              = now.addingTimeInterval(-1 * 3600)
        state.firstPendingDate           = now.addingTimeInterval(-5 * 24 * 3600)
        state.installomatorVersionAtLastScan = "2024-12-01"
        state.deferralCount              = 3

        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SchedulerState.self, from: try encoder.encode(state))

        #expect(decoded.initialScanDelaySeconds    == 3600)
        #expect(decoded.installomatorVersionAtLastScan == "2024-12-01")
        #expect(decoded.deferralCount              == 3)

        // Dates survive ISO8601 round-trip within 1-second tolerance
        let pairs: [(Date?, Date?)] = [
            (decoded.firstLaunchDate,  state.firstLaunchDate),
            (decoded.lastScanDate,     state.lastScanDate),
            (decoded.lastCheckDate,    state.lastCheckDate),
            (decoded.lastStageDate,    state.lastStageDate),
            (decoded.lastApplyDate,    state.lastApplyDate),
            (decoded.firstPendingDate, state.firstPendingDate),
        ]
        for (a, b) in pairs {
            #expect(abs(a!.timeIntervalSince(b!)) < 1.0)
        }
    }

    @Test func roundTripWithNilDates() throws {
        let state   = SchedulerState()   // all dates nil
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SchedulerState.self, from: try encoder.encode(state))

        #expect(decoded.firstLaunchDate   == nil)
        #expect(decoded.lastScanDate      == nil)
        #expect(decoded.firstPendingDate  == nil)
        #expect(decoded.deferralCount     == 0)
    }
}
