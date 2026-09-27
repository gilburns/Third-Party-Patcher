//
//  NotifierAppDelegate.swift
//  PatcherNotifier
//

import AppKit
import OSLog
import UserNotifications

nonisolated let notifierLog = os.Logger(subsystem: "com.gilburns.PatcherNotifier", category: "notifier")

final class NotifierAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Seconds with no queue activity before the agent quits. launchd relaunches it
    /// via WatchPaths when the next event is queued, and macOS relaunches it if the
    /// user interacts with a delivered notification.
    private static let idleSeconds: TimeInterval = 30

    private let delivery = NotificationDelivery()
    private var queueWatcher: DispatchSourceFileSystemObject?
    private var idleTimer: Timer?
    private var retryTimer: Timer?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Must be set before launch completes so a notification click that
        // relaunched the app is routed to this delegate.
        UNUserNotificationCenter.current().delegate = self
        registerCategories()
    }

    /// Blocking-app prompts carry one button; closing the notification means "skip",
    /// which needs .customDismissAction for the dismissal to reach the delegate.
    private func registerCategories() {
        let quit = UNNotificationAction(identifier: NotificationResponseAction.quitAndUpdate.rawValue,
                                        title: "Quit & Update", options: [])
        let prompt = UNNotificationCategory(identifier: PatcherNotificationEvent.blockingPromptCategory,
                                            actions: [quit], intentIdentifiers: [],
                                            options: [.customDismissAction])
        UNUserNotificationCenter.current().setNotificationCategories([prompt])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])
                notifierLog.info("Notification authorization granted: \(granted, privacy: .public)")
            } catch {
                notifierLog.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            }
            startWatchingQueue()
            resetIdleTimer()
            deliver()
        }
    }

    // MARK: - Delivery

    private func deliver() {
        Task {
            scheduleRetry(after: await delivery.deliverPending())
        }
    }

    /// Re-runs delivery once a held-back replacement is due, and keeps the agent
    /// alive until then so it isn't stranded in the queue until the next launch.
    private func scheduleRetry(after seconds: TimeInterval?) {
        guard let seconds else { return }
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: seconds + 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.deliver()
            }
        }
        resetIdleTimer()
    }

    // MARK: - Queue watching

    /// launchd only relaunches on WatchPaths changes while the agent is not running,
    /// so watch the folder ourselves for events queued during the idle window.
    private func startWatchingQueue() {
        let fd = open(UserNotificationQueue.folderURL.path, O_EVTONLY)
        guard fd >= 0 else {
            notifierLog.error("Could not open queue folder \(UserNotificationQueue.folderURL.path, privacy: .public)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.queueChanged()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        queueWatcher = source
    }

    private func queueChanged() {
        resetIdleTimer()
        deliver()
    }

    // MARK: - Idle exit

    private func resetIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.quitWhenIdle()
            }
        }
    }

    private func quitWhenIdle() {
        Task {
            // Final pass closes the window between the last watcher event and exit.
            if let retry = await delivery.deliverPending() {
                // A replacement is still being held on screen — stay for it.
                scheduleRetry(after: retry)
                return
            }
            queueWatcher?.cancel()
            NSApp.terminate(nil)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let content          = response.notification.request.content
        let eventID          = content.userInfo["eventID"] as? String ?? ""
        let category         = content.categoryIdentifier
        let actionIdentifier = response.actionIdentifier
        notifierLog.info("Notification response '\(actionIdentifier, privacy: .public)' for \(eventID, privacy: .public)")

        Task { @MainActor in
            self.resetIdleTimer()
            self.handleResponse(actionIdentifier: actionIdentifier, eventID: eventID,
                                category: category, completion: completionHandler)
        }
    }

    private func handleResponse(actionIdentifier: String, eventID: String, category: String,
                                completion: @escaping () -> Void) {
        let action: NotificationResponseAction?
        switch actionIdentifier {
        case NotificationResponseAction.quitAndUpdate.rawValue: action = .quitAndUpdate
        // Clicking the notification body removes it just like Close does, leaving nothing
        // to answer — treat both as "skip" rather than letting the timer force-quit the app.
        case UNNotificationDismissActionIdentifier,
             UNNotificationDefaultActionIdentifier:             action = .skip
        default:                                                action = nil
        }
        guard category == PatcherNotificationEvent.blockingPromptCategory, let action, !eventID.isEmpty else {
            completion()
            return
        }
        SchedulerRelay.send(eventID: eventID, action: action) {
            Task { @MainActor in completion() }
        }
    }
}
