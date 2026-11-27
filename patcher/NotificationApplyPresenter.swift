//
//  NotificationApplyPresenter.swift
//  patcher
//
//  Notification-based apply (ApplyDialogSize = notifications). Instead of a progress
//  window, events are queued for PatcherNotifier to post to Notification Center:
//
//    • Apps that aren't running are installed without interruption; a result
//      notification follows once the pass completes.
//    • A running blocking app gets an actionable "Quit & Update" notification. patcher
//      waits up to BlockingProcessCountdownSeconds for a response, and proceeds as soon
//      as the user quits the app themselves. Closing the notification skips the update;
//      no response force-quits the app, matching the blocking-app prompt's timer.
//

import Foundation

final class NotificationApplyPresenter: ApplyPresenter {

    private static let threadID = "apply"

    /// The user this run's notifications are delivered to and prompts are answered by.
    let uid: uid_t
    var promptUID: uid_t? { uid }

    private init(uid: uid_t) { self.uid = uid }

    /// Queues `event` for this run's user only.
    private func enqueue(_ event: PatcherNotificationEvent) {
        UserNotificationQueue.enqueue(event.targeted(to: uid))
    }

    /// Labels whose app the user has been prompted to quit. Their notification is
    /// replaced in place as the install progresses, rather than batched at the end.
    private var promptedLabels: Set<String> = []
    /// Successful installs not tied to a prompt, posted together by `complete`.
    private var installed: [(item: ApplyItem, version: String)] = []

    /// Returns a presenter, or nil when notifications can't reach the user — in which
    /// case the caller falls back to the apply window. A prompt that nobody can see would
    /// time out and force-quit the app, so the notifier must actually be loaded.
    static func makeIfAvailable() -> NotificationApplyPresenter? {
        guard let uid = consoleUserUID, uid > 0 else {
            Logger.log("ℹ️ Notifications: no console user logged in.")
            return nil
        }
        guard PatcherNotifierAgent.isInstalled else {
            Logger.log("ℹ️ Notifications: PatcherNotifier not found at \(AppConstants.patcherNotifierAppURL.path).")
            return nil
        }
        guard PatcherNotifierAgent.isLoaded(uid: uid) else {
            Logger.log("ℹ️ Notifications: PatcherNotifier LaunchAgent is not loaded for uid \(uid).")
            return nil
        }
        return NotificationApplyPresenter(uid: uid)
    }

    private func notificationID(for item: ApplyItem) -> String { "apply.\(item.label)" }

    // MARK: - ApplyPresenter

    func launchProgressDialog(items: [ApplyItem]) {}
    func setProgressText(_ text: DialogText) {}
    func waitForDialog(timeout: TimeInterval?) {}
    func dismiss() {}

    /// Notifications don't show progress within an install.
    func setItemProgress(item: ApplyItem, detail: ProgressDetail) {}

    func setInProgress(item: ApplyItem, current: Int, total: Int) {
        // Only the prompted app's user is waiting on this; everything else installs quietly.
        guard promptedLabels.contains(item.label) else { return }
        enqueue(PatcherNotificationEvent(
            kind:      .applyInProgress,
            title:     .updatingAppTitle(app: item.displayName),
            body:      .appBeingUpdated(app: item.displayName),
            threadID:  Self.threadID,
            iconPath:  item.iconPath,
            label:     item.label,
            replaceID: notificationID(for: item)
        ))
    }

    func setSuccess(item: ApplyItem, toVersion: String) {
        if promptedLabels.contains(item.label) {
            enqueue(installedEvent(item: item, version: toVersion,
                                                         kind: .applyInstalled, background: false,
                                                         replaceID: notificationID(for: item)))
        } else {
            installed.append((item, toVersion))
        }
    }

    func setFailed(item: ApplyItem) {
        enqueue(PatcherNotificationEvent(
            kind:      .applyFailed,
            title:     .appUpdateFailedTitle(app: item.displayName),
            body:      .updateWillBeRetried(app: item.displayName),
            threadID:  Self.threadID,
            iconPath:  item.iconPath,
            label:     item.label,
            replaceID: notificationID(for: item)
        ))
    }

    func setSkipped(item: ApplyItem, reason: SkipReason) {
        // Clear a prompt that is still showing (e.g. the user skipped, or the run ended).
        // Informational "please quit" notices stay up — they're the only record of why.
        if promptedLabels.contains(item.label) {
            enqueue(.withdraw(replaceID: notificationID(for: item)))
        }
    }

    func complete(applied: Int, skipped: Int, failed: Int) {
        queueInstalledNotifications(installed, kind: .applyInstalled, threadID: Self.threadID, background: false,
                                    targetUID: uid)
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
            enqueue(PatcherNotificationEvent(
                kind:      .blockingNotify,
                title:     .updatePendingTitle(app: item.displayName),
                body:      .quitWhenConvenient(app: item.displayName),
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
            title:     .appUpdateReadyTitle(app: item.displayName),
            body:      .quitAndUpdatePrompt(process: processName, seconds: countdownSeconds),
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
        enqueue(event)
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
            if deferIfScreenLocks, isAwayFromScreen(uid: uid) {
                // The prompt is withdrawn by setSkipped when the apply loop handles the skip.
                Logger.log("🔒 Screen locked or user switched away while prompting for '\(processName)' — skipping \(item.label)")
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

private func installedEvent(item: ApplyItem, version: String,
                            kind: PatcherNotificationEvent.Kind, background: Bool,
                            replaceID: String? = nil, threadID: String = "apply") -> PatcherNotificationEvent {
    PatcherNotificationEvent(
        kind:      kind,
        title:     .appUpdatedTitle(app: item.displayName),
        body:      .appWasUpdated(app: item.displayName, version: version.isEmpty ? nil : version,
                                  background: background),
        threadID:  threadID,
        iconPath:  item.iconPath,
        label:     item.label,
        replaceID: replaceID
    )
}

/// Posts "X was updated" notifications. Up to two items get their own notification
/// (with the app's icon); three or more are combined into a single summary so a large
/// pass doesn't flood Notification Center.
func queueInstalledNotifications(_ installed: [(item: ApplyItem, version: String)],
                                 kind: PatcherNotificationEvent.Kind, threadID: String, background: Bool,
                                 targetUID: uid_t? = nil) {
    guard !installed.isEmpty else { return }
    if installed.count <= 2 {
        for (item, version) in installed {
            UserNotificationQueue.enqueue(installedEvent(item: item, version: version, kind: kind,
                                                         background: background, threadID: threadID)
                                            .targeted(to: targetUID))
        }
    } else {
        let lines = installed.map { $0.version.isEmpty ? $0.item.displayName : "\($0.item.displayName) \($0.version)" }
        UserNotificationQueue.enqueue(PatcherNotificationEvent(
            kind:     kind,
            title:    .appsUpdatedTitle(count: installed.count),
            body:     .appList(lines),
            threadID: threadID
        ).targeted(to: targetUID))
    }
}
