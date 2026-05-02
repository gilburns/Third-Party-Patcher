//
//  PatcherScheduler.swift
//  patcher
//
//  Created by Gil Burns on 4/15/26.
//

import Foundation

// MARK: - Scheduler

struct PatcherScheduler {

    let prefs: Preferences

    func runCycle() {

        // 1. One-time initial deployment delay.
        guard initialDeploymentDelayElapsed() else {
            Logger.log("ℹ️ Initial deployment delay has not elapsed — skipping cycle.")
            return
        }

        // 2. MenuBar app LaunchAgent management.
        manageMenuBarApp()

        var state   = SchedulerState.load()
        let now     = Date()
        var dirty   = false
        var scanRan = false

        // ── Pre-evaluate which network-dependent phases are due ───────────────
        // Computed upfront so we can perform one connectivity check before
        // touching the network, rather than failing mid-run.
        let scanDue   = shouldRunScan(state: state, now: now)
        // Check is only relevant when scan won't already cover it this cycle.
        let checkDue  = !scanDue && shouldRunCheck(state: state, now: now)
        let stageDue  = shouldRunStage(state: state, now: now)
        let dialogDue = prefs.swiftDialogEnabled &&
                        !FileManager.default.fileExists(atPath: AppConstants.swiftDialogBinaryURL.path)

        // ── Internet connectivity check ───────────────────────────────────────
        // Performed once, only when at least one phase requires the network.
        // Verifies real internet access AND rules out captive-portal situations
        // by confirming the response body from captive.apple.com says "Success".
        // apply is intentionally excluded — it runs from already-staged files.
        let networkPhaseDue = scanDue || checkDue || stageDue || dialogDue
        let networkOK: Bool
        if networkPhaseDue {
            networkOK = isInternetAvailable()
            if !networkOK {
                Logger.log("⚠️ No internet connectivity (or captive portal detected) — scan/check/stage skipped this cycle.")
            }
        } else {
            networkOK = true   // no network phase due; value unused below
        }

        // ── Bootstrap: ensure swiftDialog is installed before apply can use it ──
        if dialogDue && networkOK { ensureSwiftDialog() }

        // ── Scan ──────────────────────────────────────────────────────────────
        // Long interval (default 30 days). Also fires when Installomator labels
        // have been updated since the last scan.
        // Scan discovers apps AND checks versions — no separate check needed after.
        // Silent and read-only — no Focus check.
        if scanDue && networkOK {
            writeActivePhase("scan")
            runSubcommand("scan")
            clearActivePhase()
            state.lastScanDate   = now
            state.lastCheckDate  = now   // scan includes the check — reset check timer too
            state.installomatorVersionAtLastScan = loadEffectiveLabelsVersion()
            scanRan = true
            dirty   = true
        }

        // ── Check ─────────────────────────────────────────────────────────────
        // Short interval (default 24 h). Checks versions for already-discovered apps.
        // Skipped when scan ran this cycle — scan already performed the same work.
        if checkDue && networkOK {
            writeActivePhase("check")
            runSubcommand("check")
            clearActivePhase()
            state.lastCheckDate = now
            dirty = true
        } else if scanRan {
            Logger.log("ℹ️ Check: skipped — scan ran this cycle.")
        }

        // ── Stage ─────────────────────────────────────────────────────────────
        // Same interval as check (default 24 h). Downloads pending updates.
        // Check display assertions — a download can saturate bandwidth during a
        // presentation. Focus/DND alone doesn't block a silent background download.
        if stageDue && networkOK {
            let bypassFocus = isFocusDeadlineReached(state: state, now: now) || isHardDeadlineReached(state: state, now: now)
            if prefs.focusCheckEnabled && !bypassFocus,
               let presenter = FocusDetector.activeDisplayAssertion() {
                Logger.log("⏸️ Stage deferred — display assertion held by '\(presenter)'")
            } else {
                writeActivePhase("stage")
                runSubcommand("stage")
                clearActivePhase()
                state.lastStageDate = now
                // Track when updates first appeared so daysPending is accurate at apply time.
                if hasStagedUpdates() {
                    if state.firstPendingDate == nil {
                        state.firstPendingDate = now
                        Logger.log("ℹ️ Pending updates detected — firstPendingDate set to \(now).")
                    }
                } else {
                    state.firstPendingDate = nil
                }
                dirty = true
            }
        }

        // ── Apply ─────────────────────────────────────────────────────────────
        // Gated by the apply schedule (monthly cadence or deadline-based).
        // Checks active deferrals, Focus blockers, and hard deadline.
        if let applySchedule = resolveApplySchedule(state: state, now: now) {
            let deferralState = DeferralState.load()
            if deferralState.isActive(now: now) {
                Logger.log("⏸️ Apply: deferral active — \(formatDeferralDuration(deferralState.remainingMinutes(now: now))) remaining.")
            } else if prefs.focusCheckEnabled && !applySchedule.focusDeadlineReached && !applySchedule.hardDeadlineReached,
               let blocker = FocusDetector.activeBlocker() {
                let focusMins = prefs.deferralTimerFocus
                var deferral = DeferralState.load()
                deferral.recordFocusDeferral(minutes: focusMins)
                deferral.save()
                Logger.log("⏸️ Apply deferred \(formatDeferralDuration(focusMins)) — \(blocker)")
            } else {
                if applySchedule.hardDeadlineReached {
                    Logger.log("⚠️ Hard deadline reached — forcing apply regardless of Focus / deferral.")
                } else if applySchedule.focusDeadlineReached {
                    Logger.log("⚠️ Focus deadline reached — ignoring Focus / presentation state.")
                }
                let daysPending = state.firstPendingDate.map {
                    Calendar.current.dateComponents([.day], from: $0, to: now).day ?? 0
                } ?? 0
                let applyArgs = daysPending > 0 ? ["--days-pending", "\(daysPending)"] : []
                writeActivePhase("apply")
                runSubcommand("apply", args: applyArgs)
                clearActivePhase()
                state.lastApplyDate = now
                // Clear firstPendingDate once all staged updates have been installed.
                if !hasStagedUpdates() {
                    state.firstPendingDate = nil
                    Logger.log("ℹ️ All updates applied — firstPendingDate cleared.")
                }
                dirty = true
            }
        }

        if dirty { state.save() }
    }


    // MARK: - Initial deployment delay

    private func initialDeploymentDelayElapsed() -> Bool {
        guard prefs.initialScanDelayEnabled else { return true }

        var state = SchedulerState.load()
        let now   = Date()

        if state.firstLaunchDate == nil {
            state.firstLaunchDate = now
            let maxDelay = max(0, prefs.initialScanDelayMaxSeconds)
            state.initialScanDelaySeconds = maxDelay > 0 ? Int.random(in: 0...maxDelay) : 0
            state.save()
            let hours = String(format: "%.1f", Double(state.initialScanDelaySeconds!) / 3600.0)
            Logger.log("ℹ️ First launch — initial scan delay set to \(state.initialScanDelaySeconds!)s (\(hours)h).")
            return false
        }

        guard let firstLaunch  = state.firstLaunchDate,
              let delaySeconds = state.initialScanDelaySeconds else {
            return true
        }

        let remaining = TimeInterval(delaySeconds) - now.timeIntervalSince(firstLaunch)
        if remaining > 0 {
            let h = Int(remaining) / 3600
            let m = (Int(remaining) % 3600) / 60
            Logger.log(String(format: "ℹ️ Initial scan delay: %dh %02dm remaining — exiting.", h, m))
            return false
        }

        return true
    }


    // MARK: - Per-subcommand due checks

    func shouldRunScan(state: SchedulerState, now: Date) -> Bool {
        guard let lastScan = state.lastScanDate else {
            Logger.log("ℹ️ Scan: never run — scheduling now.")
            return true
        }

        let intervalDays = prefs.scanIntervalDays
        let daysSince = Calendar.current.dateComponents([.day], from: lastScan, to: now).day ?? 0

        if daysSince >= intervalDays {
            Logger.log("ℹ️ Scan: due (\(daysSince)d since last, interval \(intervalDays)d).")
            return true
        }

        if prefs.scanOnLabelUpdate {
            let current = loadEffectiveLabelsVersion()
            let atLastScan = state.installomatorVersionAtLastScan ?? ""
            if !current.isEmpty && current != atLastScan {
                Logger.log("ℹ️ Scan: labels updated (\(atLastScan.isEmpty ? "none" : atLastScan) → \(current)) — triggering scan.")
                return true
            }
        }

        Logger.log("ℹ️ Scan: not due (\(daysSince)/\(intervalDays)d since last scan).")
        return false
    }

    func shouldRunCheck(state: SchedulerState, now: Date) -> Bool {
        guard let lastCheck = state.lastCheckDate else {
            Logger.log("ℹ️ Check: never run — scheduling now.")
            return true
        }
        let intervalHours = prefs.checkIntervalHours
        let hoursSince = Int(now.timeIntervalSince(lastCheck) / 3600)
        if hoursSince >= intervalHours {
            Logger.log("ℹ️ Check: due (\(hoursSince)h since last, interval \(intervalHours)h).")
            return true
        }
        Logger.log("ℹ️ Check: not due (\(hoursSince)/\(intervalHours)h since last check).")
        return false
    }

    func shouldRunStage(state: SchedulerState, now: Date) -> Bool {
        guard let lastStage = state.lastStageDate else {
            Logger.log("ℹ️ Stage: never run — scheduling now.")
            return true
        }
        let intervalHours = prefs.stageIntervalHours
        let hoursSince = Int(now.timeIntervalSince(lastStage) / 3600)
        if hoursSince >= intervalHours {
            Logger.log("ℹ️ Stage: due (\(hoursSince)h since last, interval \(intervalHours)h).")
            return true
        }
        Logger.log("ℹ️ Stage: not due (\(hoursSince)/\(intervalHours)h since last stage).")
        return false
    }


    // MARK: - Apply schedule

    /// Returns an ApplySchedule when apply should run this cycle, nil otherwise.
    /// The monthly cadence gates apply to a specific day/time window; deadline mode
    /// runs apply once per applyIntervalHours once pending updates are known.
    private func resolveApplySchedule(state: SchedulerState, now: Date) -> ApplySchedule? {
        if prefs.monthlyPatchingCadenceEnabled {
            return resolveMonthlyApplySchedule(state: state, now: now)
        } else {
            return resolveDeadlineApplySchedule(state: state, now: now)
        }
    }

    func resolveMonthlyApplySchedule(state: SchedulerState, now: Date) -> ApplySchedule? {
        let cal = Calendar.current
        guard let targetDate = monthlyTargetDate(for: now) else {
            Logger.log("⚠️ Apply: could not compute monthly target date.")
            return nil
        }

        let isPatchDay     = cal.isDate(now, inSameDayAs: targetDate)
        let isPastPatchDay = !isPatchDay && now > targetDate

        guard isPatchDay || isPastPatchDay else {
            Logger.log("ℹ️ Apply: monthly — patch day is \(formatted(targetDate)).")
            return nil
        }

        if isPatchDay {
            // On the patch day: respect the configured time window.
            guard isWithinPatchingWindow(now: now) else {
                Logger.log("ℹ️ Apply: monthly — today is patch day but outside time window.")
                return nil
            }
            // Don't re-trigger on every 10-minute wake if apply already ran today.
            if let lastApply = state.lastApplyDate, cal.isDate(lastApply, inSameDayAs: now) {
                Logger.log("ℹ️ Apply: monthly — already applied today.")
                return nil
            }
        } else {
            // After the patch day: updates remain pending (e.g. deferred or blocked).
            // Retry every applyIntervalHours rather than every 10-minute wake.
            if let lastApply = state.lastApplyDate {
                let hoursSince    = Int(now.timeIntervalSince(lastApply) / 3600)
                let intervalHours = prefs.applyIntervalHours
                if hoursSince < intervalHours {
                    Logger.log("ℹ️ Apply: monthly — not due (\(hoursSince)/\(intervalHours)h since last apply).")
                    return nil
                }
            }
        }

        return ApplySchedule(
            focusDeadlineReached: isFocusDeadlineReached(state: state, now: now),
            hardDeadlineReached:  isHardDeadlineReached(state: state, now: now)
        )
    }

    func resolveDeadlineApplySchedule(state: SchedulerState, now: Date) -> ApplySchedule? {
        guard let referenceDate = state.firstPendingDate else {
            Logger.log("ℹ️ Apply: no pending updates recorded — skipping.")
            return nil
        }

        // Respect applyIntervalHours — don't apply every 10-minute wake.
        if let lastApply = state.lastApplyDate {
            let hoursSince = Int(now.timeIntervalSince(lastApply) / 3600)
            let intervalHours = prefs.applyIntervalHours
            if hoursSince < intervalHours {
                Logger.log("ℹ️ Apply: not due (\(hoursSince)/\(intervalHours)h since last apply).")
                return nil
            }
        }

        let daysPending = Calendar.current.dateComponents([.day], from: referenceDate, to: now).day ?? 0
        Logger.log("ℹ️ Apply: deadline mode — \(daysPending) day(s) pending (focus \(prefs.deadlineDaysFocus)d, hard \(prefs.deadlineDaysHard)d).")
        return ApplySchedule(
            focusDeadlineReached: prefs.deadlineDaysFocus > 0 && daysPending >= prefs.deadlineDaysFocus,
            hardDeadlineReached:  prefs.deadlineDaysHard  > 0 && daysPending >= prefs.deadlineDaysHard
        )
    }

    func isFocusDeadlineReached(state: SchedulerState, now: Date) -> Bool {
        let limit = prefs.deadlineDaysFocus
        guard limit > 0 else { return false }
        return daysPendingForDeadline(state: state, now: now) >= limit
    }

    func isHardDeadlineReached(state: SchedulerState, now: Date) -> Bool {
        let limit = prefs.deadlineDaysHard
        guard limit > 0 else { return false }
        return daysPendingForDeadline(state: state, now: now) >= limit
    }

    /// Days elapsed for deadline calculations.
    /// Monthly mode: days since this month's patch day.
    /// Deadline mode: days since the first pending update was staged.
    private func daysPendingForDeadline(state: SchedulerState, now: Date) -> Int {
        if prefs.monthlyPatchingCadenceEnabled {
            guard let targetDate = monthlyTargetDate(for: now), targetDate <= now else { return 0 }
            return Calendar.current.dateComponents([.day], from: targetDate, to: now).day ?? 0
        } else {
            guard let firstPending = state.firstPendingDate else { return 0 }
            return Calendar.current.dateComponents([.day], from: firstPending, to: now).day ?? 0
        }
    }


    // MARK: - Helpers

    /// Returns true when the device has working internet access and is not behind
    /// a captive portal.  Makes a synchronous GET to https://captive.apple.com and
    /// confirms the body contains "Success" — exactly what Apple's own connectivity
    /// probe uses.  A captive-portal redirect returns different HTML, so it is
    /// treated the same as no connectivity.
    private func isInternetAvailable() -> Bool {
        guard let url = URL(string: "https://captive.apple.com") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        var available = false
        let semaphore = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard error == nil,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let body = data.flatMap({ String(data: $0, encoding: .utf8) }) else { return }
            available = body.contains("Success")
        }.resume()

        semaphore.wait()
        Logger.log(available
            ? "ℹ️ Connectivity: internet available."
            : "ℹ️ Connectivity: check failed (no route or captive portal).")
        return available
    }

    @discardableResult
    private func runSubcommand(_ subcommand: String, args: [String] = []) -> Bool {
        let fullArgs = ([subcommand] + args).joined(separator: " ")
        Logger.log("▶️ Running: patcher \(fullArgs)")
        let process = Process()
        process.executableURL = AppConstants.patcherBinaryURL
        process.arguments = [subcommand] + args
        do {
            try process.run()
            activeChildProcess = process      // expose to SIGTERM handler
            process.waitUntilExit()
            activeChildProcess = nil
            let ok = process.terminationStatus == 0
            Logger.log(ok ? "✅ patcher \(fullArgs) completed" : "❌ patcher \(fullArgs) exited \(process.terminationStatus)")
            return ok
        } catch {
            activeChildProcess = nil
            Logger.log("❌ Failed to launch patcher \(fullArgs): \(error)")
            return false
        }
    }

    /// Ensures swiftDialog is installed. Called before the normal scheduling
    /// loop when SwiftDialogEnabled is true. Uses `patcher ensure dialog`
    /// to scan, stage, and apply in one shot so swiftDialog is always available
    /// for the apply phase.
    private func ensureSwiftDialog() {
        guard !FileManager.default.fileExists(atPath: AppConstants.swiftDialogBinaryURL.path) else {
            Logger.log("ℹ️ swiftDialog: already installed at \(AppConstants.swiftDialogBinaryURL.path)")
            return
        }
        Logger.log("ℹ️ swiftDialog: not found — bootstrapping via 'patcher ensure swiftdialog'")
        runSubcommand("ensure", args: ["dialog"])
    }

    private func loadEffectiveLabelsVersion() -> String {
        let installomator: String
        if prefs.installomatorLabelsDisable {
            installomator = ""
        } else {
            installomator = (try? String(contentsOf: AppConstants.installomatorVersionFileURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let managed = (try? String(contentsOf: AppConstants.managedLabelsVersionFileURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (installomator.isEmpty, managed.isEmpty) {
        case (false, false): return "\(installomator)+managed:\(managed)"
        case (false, true):  return installomator
        case (true,  false): return "managed:\(managed)"
        case (true,  true):  return ""
        }
    }

    func monthlyTargetDate(for date: Date) -> Date? {
        var cal = Calendar.current
        cal.locale = Locale(identifier: "en_US_POSIX")
        var comps = cal.dateComponents([.year, .month], from: date)
        comps.weekday        = prefs.patchingWeekday
        comps.weekdayOrdinal = prefs.patchingWeekOfMonth
        return cal.date(from: comps)
    }

    func isWithinPatchingWindow(now: Date) -> Bool {
        let start = prefs.patchingStartTime
        let end   = prefs.patchingEndTime
        guard !start.isEmpty, !end.isEmpty else { return true }

        let cal = Calendar.current
        let nowMin = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)

        func toMin(_ hhmm: String) -> Int? {
            let parts = hhmm.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else { return nil }
            return parts[0] * 60 + parts[1]
        }
        guard let s = toMin(start), let e = toMin(end) else { return true }
        return nowMin >= s && nowMin <= e
    }

    private func formatted(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }

    /// Returns true if any label cache directory contains a staged install file
    /// (i.e. any file other than metadata.json and history.json).
    // MARK: - MenuBar app LaunchAgent management

    /// Reconciles the `ShowMenuBarApp` preference against the actual LaunchAgent plist.
    /// Called once per scheduler wake — is a no-op in the common case where state already matches.
    private func manageMenuBarApp() {
        let plistURL   = AppConstants.patcherMenuLaunchAgentURL
        let plistExists = FileManager.default.fileExists(atPath: plistURL.path)

        if prefs.showMenuBarApp {
            guard !plistExists else { return }
            let binaryURL = AppConstants.patcherMenuAppURL
                .appendingPathComponent("Contents/MacOS/PatcherMenu")
            guard FileManager.default.fileExists(atPath: binaryURL.path) else {
                Logger.log("⚠️ PatcherMenu binary not found at \(binaryURL.path) — skipping LaunchAgent install.")
                return
            }
            guard writePatcherMenuLaunchAgent(to: plistURL) else { return }
            guard let uid = consoleUserUID() else {
                Logger.log("⚠️ PatcherMenu: could not determine console user UID — LaunchAgent written but not bootstrapped.")
                return
            }
            let rc = runLaunchctl(["bootstrap", "gui/\(uid)", plistURL.path])
            // exit 36 = already bootstrapped; treat as success
            Logger.log(rc == 0 || rc == 36
                ? "✅ PatcherMenu LaunchAgent bootstrapped for uid \(uid)."
                : "⚠️ PatcherMenu LaunchAgent bootstrap exited \(rc).")
        } else {
            guard plistExists else { return }
            if let uid = consoleUserUID() {
                let rc = runLaunchctl(["bootout", "gui/\(uid)", plistURL.path])
                Logger.log(rc == 0
                    ? "✅ PatcherMenu LaunchAgent unloaded for uid \(uid)."
                    : "⚠️ PatcherMenu LaunchAgent bootout exited \(rc) — removing plist anyway.")
            } else {
                Logger.log("⚠️ PatcherMenu: could not determine console user UID — removing plist without bootout.")
            }
            do {
                try FileManager.default.removeItem(at: plistURL)
                Logger.log("✅ PatcherMenu LaunchAgent plist removed.")
            } catch {
                Logger.log("❌ Failed to remove PatcherMenu LaunchAgent plist: \(error)")
            }
        }
    }

    /// Writes the PatcherMenu LaunchAgent plist to the given URL.
    @discardableResult
    private func writePatcherMenuLaunchAgent(to url: URL) -> Bool {
        let binaryPath = AppConstants.patcherMenuAppURL
            .appendingPathComponent("Contents/MacOS/PatcherMenu").path
        let plist: [String: Any] = [
            "Label":           AppConstants.patcherMenuLaunchAgentLabel,
            "ProgramArguments": [binaryPath],
            "RunAtLoad":       true,
            "KeepAlive":       true
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            Logger.log("✅ PatcherMenu LaunchAgent written to \(url.path)")
            return true
        } catch {
            Logger.log("❌ Failed to write PatcherMenu LaunchAgent: \(error)")
            return false
        }
    }

    /// Returns the UID of the user currently logged in at the console,
    /// or nil if no user is logged in or the owner cannot be determined.
    private func consoleUserUID() -> uid_t? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/stat")
        process.arguments = ["-f", "%u", "/dev/console"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let uid = uid_t(output), uid > 0 else { return nil }
        return uid
    }

    /// Runs launchctl with the given arguments. Returns the exit code.
    @discardableResult
    private func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments     = arguments
        process.standardOutput = Pipe()
        process.standardError  = Pipe()
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func hasStagedUpdates() -> Bool {
        let cacheURL = AppConstants.patcherCacheFolderURL
        guard let labelDirs = try? FileManager.default.contentsOfDirectory(
            at: cacheURL, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return false }

        for labelDir in labelDirs {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: labelDir.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: labelDir, includingPropertiesForKeys: nil
            )) ?? []
            let hasStagedFile = contents.contains {
                $0.lastPathComponent != "metadata.json" && $0.lastPathComponent != "history.json"
            }
            if hasStagedFile { return true }
        }
        return false
    }


    // MARK: - On-demand phase (XPC-triggered)

    /// Runs a single phase immediately, bypassing cadence checks.
    /// Called from the XPC handler on the serial work queue.
    func runOnDemand(phase: String) {
        Logger.log("▶️ On-demand '\(phase)' triggered via XPC.")
        var state = SchedulerState.load()
        let now   = Date()
        var dirty = false

        let showProgress = Preferences().showScanCheckProgressDialog

        switch phase {
        case "scan":
            writeActivePhase("scan", triggeredBy: "xpc")
            runSubcommand("scan", args: showProgress ? ["--user-initiated"] : [])
            clearActivePhase()
            state.lastScanDate  = now
            state.lastCheckDate = now
            state.installomatorVersionAtLastScan = loadEffectiveLabelsVersion()
            dirty = true

        case "check":
            writeActivePhase("check", triggeredBy: "xpc")
            runSubcommand("check", args: showProgress ? ["--user-initiated"] : [])
            clearActivePhase()
            state.lastCheckDate = now
            dirty = true

        case "stage":
            writeActivePhase("stage", triggeredBy: "xpc")
            runSubcommand("stage")
            clearActivePhase()
            state.lastStageDate = now
            if hasStagedUpdates() {
                if state.firstPendingDate == nil {
                    state.firstPendingDate = now
                    Logger.log("ℹ️ Pending updates detected — firstPendingDate set.")
                }
            } else {
                state.firstPendingDate = nil
            }
            dirty = true

        case "apply":
            // On-demand apply bypasses cadence and deadline checks — user explicitly requested it.
            let daysPending = state.firstPendingDate.map {
                Calendar.current.dateComponents([.day], from: $0, to: now).day ?? 0
            } ?? 0
            let applyArgs = daysPending > 0 ? ["--days-pending", "\(daysPending)"] : []
            writeActivePhase("apply", triggeredBy: "xpc")
            runSubcommand("apply", args: applyArgs)
            clearActivePhase()
            state.lastApplyDate = now
            if !hasStagedUpdates() {
                state.firstPendingDate = nil
                Logger.log("ℹ️ All updates applied — firstPendingDate cleared.")
            }
            dirty = true

        default:
            Logger.log("⚠️ runOnDemand: unrecognized phase '\(phase)'")
        }

        if dirty { state.save() }
    }


    // MARK: - Active phase status file

    private func writeActivePhase(_ phase: String, label: String? = nil, triggeredBy: String = "scheduled") {
        let url = AppConstants.patcherConfigFolderURL.appendingPathComponent("active_phase.json")
        var dict: [String: Any] = [
            "phase": phase,
            "startedAt": ISO8601DateFormatter().string(from: Date()),
            "triggeredBy": triggeredBy
        ]
        if let label { dict["label"] = label }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) else { return }
        try? FileManager.default.createDirectory(at: AppConstants.patcherConfigFolderURL,
                                                  withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Installs a single label via `patcher ensure <label>`. Generalized form of ensureSwiftDialog().
    func ensureLabel(_ label: String) {
        Logger.log("ℹ️ Self-service install: starting 'patcher ensure \(label)'")
        // Record intent before running so the event is captured even if patcher exits non-zero.
        recordSelfServiceInstall(label: label, date: Date())
        writeActivePhase("install", label: label, triggeredBy: "xpc")
        runSubcommand("ensure", args: [label])
        clearActivePhase()
        // If apply failed the staged file and metadata.json stagedTimestamp remain.
        // Clean them up so patcher doesn't treat this as a pending update on the next cycle.
        cleanupFailedSelfServiceStage(label)
        Logger.log("✅ Self-service install complete for label '\(label)'")
    }

    private func cleanupFailedSelfServiceStage(_ label: String) {
        let labelCacheURL = AppConstants.patcherCacheFolderURL.appendingPathComponent(label)
        let fm = FileManager.default

        // If metadata.json no longer has stagedTimestamp, apply succeeded — nothing to do.
        let metaURL = labelCacheURL.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metaURL),
              var meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              meta["stagedTimestamp"] != nil
        else { return }

        Logger.log("⚠️ Self-service install for '\(label)' failed — cleaning up staged files.")

        // Delete staged files (anything that isn't metadata.json or history.json).
        if let contents = try? fm.contentsOfDirectory(at: labelCacheURL, includingPropertiesForKeys: nil) {
            for file in contents where file.lastPathComponent != "metadata.json"
                                   && file.lastPathComponent != "history.json" {
                do {
                    try fm.removeItem(at: file)
                    Logger.log("🗑️ Removed staged file: \(file.lastPathComponent)")
                } catch {
                    Logger.log("❌ Failed to remove staged file \(file.lastPathComponent): \(error)")
                }
            }
        }

        // Strip staged-file keys from metadata.json, matching what appendCacheInstallTimestamp does on success.
        meta.removeValue(forKey: "stagedTimestamp")
        meta.removeValue(forKey: "appNewVersion")
        meta.removeValue(forKey: "downloadURL")
        if let updated = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? updated.write(to: metaURL, options: .atomic)
        }

        // Remove the discovered plist so patcher doesn't see this as a pending update.
        // scanSingleLabel (called by patcher ensure) creates it; on failure it must be removed.
        let discoveredURL = AppConstants.patcherDiscoveredFolderURL.appendingPathComponent("\(label).plist")
        if fm.fileExists(atPath: discoveredURL.path) {
            do {
                try fm.removeItem(at: discoveredURL)
                Logger.log("🗑️ Removed discovered plist for '\(label)' after failed self-service install.")
            } catch {
                Logger.log("❌ Failed to remove discovered plist for '\(label)': \(error)")
            }
        }
    }

    private func clearActivePhase() {
        let url = AppConstants.patcherConfigFolderURL.appendingPathComponent("active_phase.json")
        try? FileManager.default.removeItem(at: url)
    }
}
