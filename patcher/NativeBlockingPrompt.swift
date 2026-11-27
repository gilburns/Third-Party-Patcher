//
//  NativeBlockingPrompt.swift
//  patcher
//
//  The blocking-app notice and prompt, drawn by PatcherNotifier.
//
//  patcher owns the countdown. The agent reports `.displayed` once the window is on
//  screen, and the countdown only starts then: a prompt nobody has seen never counts as
//  consent to force-quit. If the acknowledgement doesn't arrive, the update is skipped.
//

import Foundation

/// Force-quits a process by exact name, then gives it a moment to exit.
func forceQuit(_ processName: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    p.arguments = ["-x", processName]
    try? p.run()
    p.waitUntilExit()
    Thread.sleep(forTimeInterval: 2.0)
}

final class NativeBlockingPrompt {

    /// How long to wait for the agent to put a window on screen. Covers a cold launch
    /// of PatcherNotifier by its LaunchAgent.
    static let displayTimeout: TimeInterval = 20
    /// How long the notice stays up.
    static let noticeSeconds = 30

    private let uid: uid_t
    /// `dialog-demo`: show the windows and report the outcome, but never quit anything.
    private let dryRun: Bool

    init(uid: uid_t, dryRun: Bool = false) {
        self.uid = uid
        self.dryRun = dryRun
    }

    // MARK: Notice

    /// BlockingProcessAction = notify. Shows the notice until OK or its timer ends.
    /// The caller skips the item either way.
    func notify(processName: String, item: ApplyItem) {
        Logger.log("ℹ️ BlockingProcessAction=notify — showing notice for '\(processName)'")
        let prefs = Preferences()
        var session = DialogSessionWriter.makeSession(
            kind: .blockingNotice, uid: uid, prefs: prefs, position: "center",
            title: .updatePendingTitle(app: item.displayName),
            message: .quitWhenConvenient(app: item.displayName),
            total: 0)
        session.icon        = "caution"
        session.overlayIcon = item.iconPath ?? packageIconPath
        session.button      = DialogSession.Button(.ok, enabled: true)
        let writer = DialogSessionWriter(session: session)
        let id     = session.id
        DialogSessionStore.removeResponses(id: id)
        defer {
            writer.close()
            DialogSessionStore.removeResponses(id: id)
        }

        guard waitForDisplay(id: id) else {
            Logger.log("⚠️ Notice for '\(processName)' was not shown within \(Int(Self.displayTimeout))s — skipping \(item.label)")
            return
        }
        if !dryRun {
            recordBlockingProcessEvent(label: item.label, type: LabelHistoryEvent.EventType.blockingProcessNotified,
                                       processName: processName, date: Date())
        }

        let ends = Date().addingTimeInterval(TimeInterval(Self.noticeSeconds))
        writer.update { s in
            s.countdown   = DialogSession.Countdown(ends: ends, seconds: Self.noticeSeconds)
            s.autoCloseAt = ends
        }
        while Date() < ends, !shutdownRequested {
            if DialogSessionStore.takeResponse(id: id, .primary) || DialogSessionStore.takeResponse(id: id, .dismissed) {
                Logger.log("ℹ️ Notice for '\(processName)' closed by the user")
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    // MARK: Prompt

    /// BlockingProcessAction = prompt. Skip Update skips; Quit <App> force-quits; the
    /// countdown ending force-quits. If the user quits the app themselves, the install goes
    /// ahead. In each case the app is reopened after the install while "Reopen <App> after
    /// the update" is checked (it starts checked).
    func prompt(processName: String, item: ApplyItem, countdownSeconds: Int,
                deferIfScreenLocks: Bool) -> BlockingActionResponse {
        Logger.log("ℹ️ BlockingProcessAction=prompt — showing prompt for '\(processName)' (\(countdownSeconds)s)")
        let prefs = Preferences()
        var session = DialogSessionWriter.makeSession(
            kind: .blockingPrompt, uid: uid, prefs: prefs, position: "center",
            title: .updatePausedTitle(app: item.displayName),
            message: .paragraphs([.needsUpdateButRunning(app: item.displayName, process: processName),
                                  .saveAndQuitOrSkip(process: processName)]),
            total: 0)
        session.icon            = "caution"
        session.overlayIcon     = item.iconPath ?? packageIconPath
        session.button          = DialogSession.Button(.skipUpdate, enabled: true)
        session.secondaryButton = DialogSession.Button(.quitApp(process: processName), enabled: true)
        session.checkbox        = DialogSession.Checkbox(label: .reopenAfterUpdate(app: item.displayName),
                                                         checked: true)
        let writer = DialogSessionWriter(session: session)
        let id     = session.id
        DialogSessionStore.removeResponses(id: id)
        defer {
            writer.close()
            DialogSessionStore.removeResponses(id: id)
        }

        func record(_ type: String) {
            guard !dryRun else { return }
            recordBlockingProcessEvent(label: item.label, type: type, processName: processName, date: Date())
        }

        guard waitForDisplay(id: id) else {
            Logger.log("⚠️ Prompt for '\(processName)' was not shown within \(Int(Self.displayTimeout))s — skipping \(item.label)")
            record(LabelHistoryEvent.EventType.blockingProcessSkipped)
            return .skip
        }

        let seconds = max(countdownSeconds, 1)
        let ends    = Date().addingTimeInterval(TimeInterval(seconds))
        writer.update { $0.countdown = DialogSession.Countdown(ends: ends, seconds: seconds) }

        // The checkbox as the user last left it.
        var reopen = true
        func proceed() -> BlockingActionResponse { reopen ? .proceedRelaunch : .proceed }
        func readToggle() {
            if let value = DialogSessionStore.takeResponseValue(id: id, .toggled) { reopen = value == "1" }
        }

        while Date() < ends {
            readToggle()
            if shutdownRequested {
                Logger.log("⚠️ Shutdown requested while waiting on '\(processName)' — skipping \(item.label)")
                return .skip
            }
            if let value = DialogSessionStore.takeResponseValue(id: id, .secondary) {
                // The click carries the checkbox state, in case its toggle hasn't arrived yet.
                if DialogSession.Checkbox.values.contains(value) { reopen = value == "1" }
                Logger.log("ℹ️ User chose to quit '\(processName)'\(dryRun ? " (demo — not quitting)" : " — force-quitting")"
                           + (reopen ? "; it will be reopened after the update" : ""))
                record(LabelHistoryEvent.EventType.blockingProcessQuit)
                if !dryRun { forceQuit(processName) }
                return proceed()
            }
            if DialogSessionStore.takeResponse(id: id, .primary) {
                Logger.log("ℹ️ User skipped update for '\(item.label)'")
                record(LabelHistoryEvent.EventType.blockingProcessSkipped)
                return .skip
            }
            if DialogSessionStore.takeResponse(id: id, .dismissed) {
                // The quit key is not consent to force-quit.
                Logger.log("ℹ️ Prompt for '\(processName)' dismissed — skipping \(item.label)")
                record(LabelHistoryEvent.EventType.blockingProcessSkipped)
                return .skip
            }
            if !dryRun, !isProcessRunning(processName) {
                Logger.log("ℹ️ '\(processName)' was quit by the user — proceeding"
                           + (reopen ? "; it will be reopened after the update" : ""))
                record(LabelHistoryEvent.EventType.blockingProcessQuit)
                return proceed()
            }
            if deferIfScreenLocks, !dryRun, isAwayFromScreen(uid: uid) {
                Logger.log("🔒 Screen locked or user switched away while prompting for '\(processName)' — skipping \(item.label)")
                record(LabelHistoryEvent.EventType.blockingProcessScreenLocked)
                return .skip
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        // The user saw the prompt and let the countdown run out.
        readToggle()
        Logger.log("ℹ️ Countdown expired for '\(processName)'\(dryRun ? " (demo — not quitting)" : " — force-quitting")"
                   + (reopen ? "; it will be reopened after the update" : ""))
        record(LabelHistoryEvent.EventType.blockingProcessTimedOut)
        if !dryRun { forceQuit(processName) }
        return proceed()
    }

    // MARK: Helpers

    /// Waits for PatcherNotifier to report the window on screen.
    private func waitForDisplay(id: String) -> Bool {
        let deadline = Date().addingTimeInterval(Self.displayTimeout)
        while Date() < deadline, !shutdownRequested {
            if DialogSessionStore.takeResponse(id: id, .displayed) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }
}
