//
//  StatusReporter.swift
//  patcherscheduler
//
//  Reads SchedulerState + Preferences and prints the current patching schedule,
//  either as a human-readable table or as JSON / plist.
//
//  Usage:
//    patcherscheduler status            → table
//    patcherscheduler status --json     → JSON
//    patcherscheduler status --plist    → plist (XML)
//

import Foundation

struct StatusReporter {

    let state: SchedulerState
    let prefs: Preferences
    let now:   Date

    init() {
        self.state = SchedulerState.load()
        self.prefs = Preferences()
        self.now   = Date()
    }

    // MARK: - Entry

    func run(args: [String]) {
        if args.contains("--json") {
            printJSON()
        } else if args.contains("--plist") {
            printPlist()
        } else {
            printTable()
        }
    }


    // MARK: - Data model

    struct PhaseInfo {
        let phase: String
        let lastRun: Date?
        let intervalLabel: String
        let nextRun: Date?          // nil = "No pending updates" / not applicable
        let note: String?           // extra contextual note (e.g. "label update trigger")
    }

    func buildPhaseInfos() -> [PhaseInfo] {
        var infos: [PhaseInfo] = []

        // ── Scan ──────────────────────────────────────────────────────────────
        let scanInterval = prefs.scanIntervalDays
        let scanNext: Date? = state.lastScanDate.map {
            Calendar.current.date(byAdding: .day, value: scanInterval, to: $0)!
        }
        var scanNote: String? = nil
        if prefs.scanOnLabelUpdate, let lastScan = state.lastScanDate {
            let current = loadInstallomatorVersion()
            let atScan  = state.installomatorVersionAtLastScan ?? ""
            if !current.isEmpty && current != atScan {
                scanNote = "label update pending (last scan: \(atScan), current: \(current))"
            }
        }
        infos.append(PhaseInfo(
            phase: "Scan",
            lastRun: state.lastScanDate,
            intervalLabel: "\(scanInterval)d",
            nextRun: scanNext,
            note: scanNote
        ))

        // ── Check ─────────────────────────────────────────────────────────────
        let checkInterval = prefs.checkIntervalHours
        let checkNext: Date? = state.lastCheckDate.map {
            $0.addingTimeInterval(TimeInterval(checkInterval * 3600))
        }
        infos.append(PhaseInfo(
            phase: "Check",
            lastRun: state.lastCheckDate,
            intervalLabel: "\(checkInterval)h",
            nextRun: checkNext,
            note: nil
        ))

        // ── Stage ─────────────────────────────────────────────────────────────
        let stageInterval = prefs.stageIntervalHours
        let stageNext: Date? = state.lastStageDate.map {
            $0.addingTimeInterval(TimeInterval(stageInterval * 3600))
        }
        infos.append(PhaseInfo(
            phase: "Stage",
            lastRun: state.lastStageDate,
            intervalLabel: "\(stageInterval)h",
            nextRun: stageNext,
            note: nil
        ))

        // ── Apply ─────────────────────────────────────────────────────────────
        let applyInterval = prefs.applyIntervalHours
        let applyNext: Date?
        let applyNote: String?

        if prefs.monthlyPatchingCadenceEnabled {
            applyNext = nextMonthlyPatchDate()
            applyNote = "monthly cadence (\(weekdayName(prefs.patchingWeekday)), week \(prefs.patchingWeekOfMonth))"
        } else if let firstPending = state.firstPendingDate {
            let daysPending = Calendar.current.dateComponents([.day], from: firstPending, to: now).day ?? 0
            if let lastApply = state.lastApplyDate {
                applyNext = lastApply.addingTimeInterval(TimeInterval(applyInterval * 3600))
            } else {
                applyNext = now   // overdue — never applied
            }
            applyNote = "deadline mode, \(daysPending)d pending (first: \(shortDate(firstPending)))"
        } else {
            applyNext = nil
            applyNote = "no pending updates recorded"
        }
        infos.append(PhaseInfo(
            phase: "Apply",
            lastRun: state.lastApplyDate,
            intervalLabel: prefs.monthlyPatchingCadenceEnabled ? "monthly" : "\(applyInterval)h",
            nextRun: applyNext,
            note: applyNote
        ))

        return infos
    }


    // MARK: - Table output

    func printTable() {
        let infos = buildPhaseInfos()
        let w = 70

        print(String(repeating: "═", count: w))
        print(" Patcher Schedule Status  —  \(shortDateTime(now))")
        if let delay = deploymentDelayLine() {
            print(" \(delay)")
        }
        print(String(repeating: "═", count: w))
        print(" \(col("Phase", 7))  \(col("Last Run", 21))  \(col("Interval", 10))  Next Run")
        print(String(repeating: "─", count: w))

        for info in infos {
            let lastStr = info.lastRun.map { shortDateTime($0) } ?? "never"
            let nextStr = nextRunString(info.nextRun)
            let relStr  = info.nextRun.map { "  (\(relativeTime($0)))" } ?? ""
            print(" \(col(info.phase, 7))  \(col(lastStr, 21))  \(col(info.intervalLabel, 10))  \(nextStr)\(relStr)")
            if let note = info.note {
                print("          ↳ \(note)")
            }
        }

        print(String(repeating: "═", count: w))
    }

    /// Left-pads (or truncates) `s` to exactly `width` characters.
    private func col(_ s: String, _ width: Int) -> String {
        if s.count >= width { return s }
        return s + String(repeating: " ", count: width - s.count)
    }


    // MARK: - JSON output

    func printJSON() {
        let dict = buildDict()
        guard let data = try? JSONSerialization.data(withJSONObject: dict,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        print(String(data: data, encoding: .utf8) ?? "")
    }


    // MARK: - Plist output

    func printPlist() {
        let dict = buildDict()
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict,
                                                              format: .xml, options: 0) else { return }
        print(String(data: data, encoding: .utf8) ?? "")
    }


    // MARK: - Shared dict builder

    private func buildDict() -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let infos = buildPhaseInfos()

        func phaseDict(_ info: PhaseInfo) -> [String: Any] {
            var d: [String: Any] = [
                "intervalLabel": info.intervalLabel,
                "isDue": info.nextRun.map { $0 <= now } ?? false
            ]
            if let lr = info.lastRun  { d["lastRun"]  = iso.string(from: lr) }
            if let nr = info.nextRun  { d["nextRun"]  = iso.string(from: nr) }
            if let note = info.note   { d["note"]     = note }
            return d
        }

        var out: [String: Any] = ["generatedAt": iso.string(from: now)]
        for info in infos { out[info.phase.lowercased()] = phaseDict(info) }

        // Initial deployment delay
        if prefs.initialScanDelayEnabled {
            var dd: [String: Any] = ["enabled": true]
            if let fl = state.firstLaunchDate {
                dd["firstLaunchDate"] = iso.string(from: fl)
                if let d = state.initialScanDelaySeconds {
                    let elapsed = now.timeIntervalSince(fl) >= TimeInterval(d)
                    dd["delaySeconds"] = d
                    dd["status"] = elapsed ? "completed" : "waiting"
                    if !elapsed {
                        let remaining = TimeInterval(d) - now.timeIntervalSince(fl)
                        dd["remainingSeconds"] = Int(remaining)
                    }
                }
            } else {
                dd["status"] = "first launch not yet recorded"
            }
            out["initialDeploymentDelay"] = dd
        } else {
            out["initialDeploymentDelay"] = ["enabled": false]
        }

        return out
    }


    // MARK: - Helpers

    private func nextRunString(_ date: Date?) -> String {
        guard let date else { return "—" }
        if date <= now { return "due now" }
        return shortDateTime(date)
    }

    private func relativeTime(_ date: Date) -> String {
        let diff = date.timeIntervalSince(now)
        if diff < 0 { return "overdue" }
        let totalMinutes = Int(diff / 60)
        let days    = totalMinutes / (60 * 24)
        let hours   = (totalMinutes % (60 * 24)) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func shortDateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    private func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func deploymentDelayLine() -> String? {
        guard prefs.initialScanDelayEnabled, let fl = state.firstLaunchDate,
              let d = state.initialScanDelaySeconds else { return nil }
        let elapsed = now.timeIntervalSince(fl) >= TimeInterval(d)
        if elapsed { return "Initial deployment delay: completed" }
        let remaining = TimeInterval(d) - now.timeIntervalSince(fl)
        return "Initial deployment delay: \(relativeTime(now.addingTimeInterval(remaining))) remaining"
    }

    private func nextMonthlyPatchDate() -> Date? {
        var cal = Calendar.current
        cal.locale = Locale(identifier: "en_US_POSIX")
        // Try this month first, then next month
        for offset in 0...1 {
            guard let baseMonth = cal.date(byAdding: .month, value: offset, to: now) else { continue }
            var comps = cal.dateComponents([.year, .month], from: baseMonth)
            comps.weekday        = prefs.patchingWeekday
            comps.weekdayOrdinal = prefs.patchingWeekOfMonth
            if let candidate = cal.date(from: comps), candidate > now { return candidate }
        }
        return nil
    }

    private func weekdayName(_ weekday: Int) -> String {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let index = max(0, min(weekday - 1, 6))
        return names[index]
    }

    private func loadInstallomatorVersion() -> String {
        (try? String(contentsOf: AppConstants.installomatorVersionFileURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
