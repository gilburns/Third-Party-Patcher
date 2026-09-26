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

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Must be set before launch completes so a notification click that
        // relaunched the app is routed to this delegate.
        UNUserNotificationCenter.current().delegate = self
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
            await delivery.deliverPending()
            startWatchingQueue()
            resetIdleTimer()
        }
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
        Task { await delivery.deliverPending() }
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
            await delivery.deliverPending()
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
        let id = response.notification.request.identifier
        notifierLog.info("Notification response '\(response.actionIdentifier, privacy: .public)' for \(id, privacy: .public)")
        Task { @MainActor in
            self.resetIdleTimer()
            completionHandler()
        }
    }
}
