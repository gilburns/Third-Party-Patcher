//
//  NotificationApplyPresenter.swift
//  patcher
//
//  Notification-based apply (ApplyDialogSize = notifications). Instead of a swiftDialog
//  window, events are queued for PatcherNotifier to post to Notification Center:
//
//    • Apps that aren't running are installed without interruption; a result
//      notification follows once the pass completes.
//    • A running blocking app gets an actionable "Quit & Update" notification. patcher
//      waits up to BlockingProcessCountdownSeconds for a response, and proceeds as soon
//      as the user quits the app themselves. Closing the notification skips the update;
//      no response force-quits the app, matching the swiftDialog prompt's timer.
//

import Foundation

final class NotificationApplyPresenter: ApplyPresenter {

    private static let threadID = "apply"

    /// Labels whose app the user has been prompted to quit. Their notification is
    /// replaced in place as the install progresses, rather than batched at the end.
    private var promptedLabels: Set<String> = []
    /// Successful installs not tied to a prompt, posted together by `complete`.
    private var installed: [(item: ApplyItem, version: String)] = []

    /// Returns a presenter, or nil when notifications can't reach the user — in which
    /// case the caller falls back to swiftDialog. A prompt that nobody can see would
    /// time out and force-quit the app, so the notifier must actually be loaded.
    static func makeIfAvailable() -> NotificationApplyPresenter? {
        guard let uid = consoleUserUID, uid > 0 else {
            Logger.log("ℹ️ Notifications: no console user logged in.")
            return nil
        }
        let binary = AppConstants.patcherNotifierAppURL.appendingPathComponent("Contents/MacOS/PatcherNotifier")
        guard FileManager.default.fileExists(atPath: binary.path) else {
            Logger.log("ℹ️ Notifications: PatcherNotifier not found at \(AppConstants.patcherNotifierAppURL.path).")
            return nil
        }
        guard isNotifierLoaded(uid: uid) else {
            Logger.log("ℹ️ Notifications: PatcherNotifier LaunchAgent is not loaded for uid \(uid).")
            return nil
        }
        return NotificationApplyPresenter()
    }

    private static func isNotifierLoaded(uid: uid_t) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["print", "gui/\(uid)/\(AppConstants.patcherNotifierLaunchAgentLabel)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError  = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private func notificationID(for item: ApplyItem) -> String { "apply.\(item.label)" }

    // MARK: - ApplyPresenter

    func launchProgressDialog(items: [ApplyItem]) {}
    func setProgressText(_ text: String) {}
    func waitForDialog(timeout: TimeInterval?) {}
    func dismiss() {}

    func setInProgress(item: ApplyItem, current: Int, total: Int) {
        // Only the prompted app's user is waiting on this; everything else installs quietly.
        guard promptedLabels.contains(item.label) else { return }
        UserNotificationQueue.enqueue(PatcherNotificationEvent(
            kind:      .applyInProgress,
            title:     "Updating \(item.displayName)",
            body:      "\(item.displayName) is being updated…",
            threadID:  Self.threadID,
            iconPath:  item.iconPath,
            label:     item.label,
            replaceID: notificationID(for: item)
        ))
    }

    func setSuccess(item: ApplyItem, toVersion: String) {
        if promptedLabels.contains(item.label) {
            UserNotificationQueue.enqueue(installedEvent(item: item, version: toVersion,
                                                         kind: .applyInstalled, background: false,
                                                         replaceID: notificationID(for: item)))
        } else {
            installed.append((item, toVersion))
        }
    }

    func setFailed(item: ApplyItem) {
        UserNotificationQueue.enqueue(PatcherNotificationEvent(
            kind:      .applyFailed,
            title:     "\(item.displayName) Couldn't Be Updated",
            body:      "The update for \(item.displayName) will be tried again later.",
            threadID:  Self.threadID,
            iconPath:  item.iconPath,
            label:     item.label,
            replaceID: notificationID(for: item)
        ))
    }

    func setSkipped(item: ApplyItem, reason: String) {
        // Clear a prompt that is still showing (e.g. the user skipped, or the run ended).
        // Informational "please quit" notices stay up — they're the only record of why.
        if promptedLabels.contains(item.label) {
            UserNotificationQueue.enqueue(.withdraw(replaceID: notificationID(for: item)))
        }
    }

    func complete(applied: Int, skipped: Int, failed: Int) {
        queueInstalledNotifications(installed, kind: .applyInstalled, threadID: Self.threadID, background: false)
    }

    func handleBlockingProcess(processName: String, item: ApplyItem,
                               action: BlockingProcessAction, countdownSeconds: Int,
                               deferIfScreenLocks: Bool) -> BlockingActionResponse {
        switch action {
        case .ignore:
            Logger.log("ℹ️ BlockingProcessAction=ignore — proceeding despite '\(processName)' running")
            return .proceed

        case .kill:
            Logger.log("ℹ️ BlockingProcessAction=kill — force-quitting '\(processName)'")
            forceQuitProcess(named: processName)
            return .proceed

        case .defer_:
            Logger.log("ℹ️ BlockingProcessAction=defer — skipping '\(item.label)' this cycle")
            return .skip

        case .notify:
            Logger.log("ℹ️ BlockingProcessAction=notify — posting notification for '\(processName)'")
            UserNotificationQueue.enqueue(PatcherNotificationEvent(
                kind:      .blockingNotify,
                title:     "Update Pending: \(item.displayName)",
                body:      "\(item.displayName) needs to be quit to apply an update. Please close it when convenient.",
                threadID:  Self.threadID,
                playSound: true,
                iconPath:  item.iconPath,
                label:     item.label,
                replaceID: notificationID(for: item)
            ))
            recordBlockingProcessEvent(label: item.label,
                                       type: LabelHistoryEvent.EventType.blockingProcessNotified,
                                       processName: processName, date: Date())
            return .skip

        case .prompt:
            return prompt(processName: processName, item: item, countdownSeconds: countdownSeconds,
                          deferIfScreenLocks: deferIfScreenLocks)
        }
    }

    // MARK: - Blocking-app prompt

    private func prompt(processName: String, item: ApplyItem, countdownSeconds: Int,
                        deferIfScreenLocks: Bool) -> BlockingActionResponse {
        Logger.log("ℹ️ BlockingProcessAction=prompt — posting Quit & Update notification for '\(processName)' (\(countdownSeconds)s)")

        let event = PatcherNotificationEvent(
            kind:      .blockingPrompt,
            title:     "\(item.displayName) Update Ready",
            body:      "Save your work and click Quit & Update, or quit \(processName) yourself. "
                     + "It will quit automatically in \(formatCountdown(countdownSeconds)). Close this notification to defer the update.",
            threadID:  Self.threadID,
            playSound: true,
            iconPath:  item.iconPath,
            label:     item.label,
            replaceID: notificationID(for: item),
            category:  PatcherNotificationEvent.blockingPromptCategory,
            // Long enough to be delivered while we wait; not so long that a late
            // PatcherNotifier launch shows a prompt nobody is waiting on.
            lifetime:  TimeInterval(countdownSeconds) + 60
        )
        UserNotificationQueue.enqueue(event)
        promptedLabels.insert(item.label)

        let deadline = Date().addingTimeInterval(TimeInterval(countdownSeconds))
        while Date() < deadline {
            if shutdownRequested {
                Logger.log("⚠️ Shutdown requested while waiting on '\(processName)' — skipping \(item.label)")
                return .skip
            }
            switch UserNotificationQueue.takeResponse(eventID: event.id) {
            case .quitAndUpdate:
                Logger.log("ℹ️ User chose Quit & Update for '\(processName)' — force-quitting")
                recordBlockingProcessEvent(label: item.label,
                                           type: LabelHistoryEvent.EventType.blockingProcessQuit,
                                           processName: processName, date: Date())
                forceQuitProcess(named: processName)
                return .proceedRelaunch
            case .skip:
                Logger.log("ℹ️ User skipped update for '\(item.label)' (notification closed)")
                recordBlockingProcessEvent(label: item.label,
                                           type: LabelHistoryEvent.EventType.blockingProcessSkipped,
                                           processName: processName, date: Date())
                return .skip
            case nil:
                break
            }
            if !isProcessRunning(processName) {
                Logger.log("ℹ️ '\(processName)' was quit by the user — proceeding")
                recordBlockingProcessEvent(label: item.label,
                                           type: LabelHistoryEvent.EventType.blockingProcessQuit,
                                           processName: processName, date: Date())
                return .proceed
            }
            if deferIfScreenLocks, isConsoleScreenLocked {
                // The prompt is withdrawn by setSkipped when the apply loop handles the skip.
                Logger.log("🔒 Screen locked while prompting for '\(processName)' — skipping \(item.label)")
                recordBlockingProcessEvent(label: item.label,
                                           type: LabelHistoryEvent.EventType.blockingProcessScreenLocked,
                                           processName: processName, date: Date())
                return .skip
            }
            Thread.sleep(forTimeInterval: 1.0)
        }

        Logger.log("ℹ️ No response for '\(processName)' within \(countdownSeconds)s — force-quitting")
        recordBlockingProcessEvent(label: item.label,
                                   type: LabelHistoryEvent.EventType.blockingProcessTimedOut,
                                   processName: processName, date: Date())
        forceQuitProcess(named: processName)
        return .proceed
    }

    private func formatCountdown(_ seconds: Int) -> String {
        if seconds >= 60, seconds % 60 == 0 {
            let minutes = seconds / 60
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        }
        return "\(seconds) seconds"
    }

    private func forceQuitProcess(named processName: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-x", processName]
        try? p.run()
        p.waitUntilExit()
        Thread.sleep(forTimeInterval: 2.0)
    }
}

// MARK: - "Updated" notifications

private func installedEvent(item: SwiftDialogController.ApplyItem, version: String,
                            kind: PatcherNotificationEvent.Kind, background: Bool,
                            replaceID: String? = nil, threadID: String = "apply") -> PatcherNotificationEvent {
    let suffix = background ? " in the background." : "."
    return PatcherNotificationEvent(
        kind:      kind,
        title:     "\(item.displayName) Updated",
        body:      version.isEmpty
            ? "\(item.displayName) was updated\(suffix)"
            : "\(item.displayName) was updated to version \(version)\(suffix)",
        threadID:  threadID,
        iconPath:  item.iconPath,
        label:     item.label,
        replaceID: replaceID
    )
}

/// Posts "X was updated" notifications. Up to two items get their own notification
/// (with the app's icon); three or more are combined into a single summary so a large
/// pass doesn't flood Notification Center.
func queueInstalledNotifications(_ installed: [(item: SwiftDialogController.ApplyItem, version: String)],
                                 kind: PatcherNotificationEvent.Kind, threadID: String, background: Bool) {
    guard !installed.isEmpty else { return }
    if installed.count <= 2 {
        for (item, version) in installed {
            UserNotificationQueue.enqueue(installedEvent(item: item, version: version, kind: kind,
                                                         background: background, threadID: threadID))
        }
    } else {
        let lines = installed.map { $0.version.isEmpty ? $0.item.displayName : "\($0.item.displayName) \($0.version)" }
        UserNotificationQueue.enqueue(PatcherNotificationEvent(
            kind:     kind,
            title:    "\(installed.count) Apps Updated",
            body:     lines.joined(separator: ", "),
            threadID: threadID
        ))
    }
}
