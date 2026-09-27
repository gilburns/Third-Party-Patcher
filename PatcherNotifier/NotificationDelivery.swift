//
//  NotificationDelivery.swift
//  PatcherNotifier
//
//  Reads pending events from the shared queue and posts each one to Notification
//  Center exactly once. Delivered event IDs are kept in this user's defaults; the
//  queue itself is root-owned and pruned by patcherscheduler.
//

import AppKit
import OSLog
import UserNotifications

final class NotificationDelivery {

    private static let deliveredIDsKey = "DeliveredEventIDs"

    /// Minimum time a notification stays on screen before a later event replaces it
    /// (e.g. "Updating Zoom" → "Zoom Updated"). patcher queues these back to back, so
    /// without a hold the intermediate states flash past before they can be read.
    static let minimumDisplaySeconds: TimeInterval = 6

    private var isDelivering = false
    private var needsAnotherPass = false

    /// Delivers everything that is due. Returns the number of seconds until a held-back
    /// replacement can be posted, or nil when nothing is waiting.
    func deliverPending() async -> TimeInterval? {
        // Watcher events arrive in bursts. If a pass is already running, have it run
        // once more when it finishes rather than starting a second one alongside it.
        guard !isDelivering else {
            needsAnotherPass = true
            return nil
        }
        isDelivering = true
        defer { isDelivering = false }

        var retryAfter: TimeInterval?
        repeat {
            needsAnotherPass = false
            if let wait = await deliverOnce() {
                retryAfter = min(retryAfter ?? wait, wait)
            }
        } while needsAnotherPass
        return retryAfter
    }

    private func deliverOnce() async -> TimeInterval? {
        let center    = UNUserNotificationCenter.current()
        let defaults  = UserDefaults.standard
        let pending   = UserNotificationQueue.pendingEvents()
        var delivered = Set(defaults.stringArray(forKey: Self.deliveredIDsKey) ?? [])

        // When each on-screen notification was posted. Read from Notification Center
        // rather than tracked locally, so the hold survives an agent relaunch.
        var shownAt: [String: Date] = [:]
        for notification in await center.deliveredNotifications() {
            shownAt[notification.request.identifier] = notification.date
        }
        var heldIDs: Set<String> = []
        var retryAfter: TimeInterval?

        for event in pending where !delivered.contains(event.id) {
            let notificationID = event.notificationID
            // Keep events for the same notification in order: once one is held back,
            // everything after it for that notification waits too.
            if heldIDs.contains(notificationID) { continue }
            if let shown = shownAt[notificationID] {
                let wait = shown.addingTimeInterval(Self.minimumDisplaySeconds).timeIntervalSinceNow
                if wait > 0 {
                    heldIDs.insert(notificationID)
                    retryAfter = min(retryAfter ?? wait, wait)
                    continue
                }
            }

            if event.kind == .withdraw {
                center.removeDeliveredNotifications(withIdentifiers: [notificationID])
                shownAt[notificationID] = nil
                delivered.insert(event.id)
                continue
            }
            do {
                try await center.add(request(for: event))
                shownAt[notificationID] = Date()
                notifierLog.info("Delivered \(event.kind.rawValue, privacy: .public) \(event.id, privacy: .public): \(event.title, privacy: .public)")
            } catch {
                // Leave undelivered so the next launch retries until the event expires.
                notifierLog.error("Failed to deliver \(event.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            delivered.insert(event.id)
        }

        // Forget IDs whose events have been pruned or expired so the set stays small.
        let pendingIDs = Set(pending.map(\.id))
        defaults.set(Array(delivered.intersection(pendingIDs)), forKey: Self.deliveredIDsKey)
        return retryAfter
    }

    private func request(for event: PatcherNotificationEvent) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title            = event.title
        content.body             = event.body
        content.threadIdentifier = event.threadID
        content.sound            = event.playSound ? .default : nil
        content.userInfo         = ["eventID": event.id, "kind": event.kind.rawValue, "label": event.label ?? ""]
        if let category = event.category {
            content.categoryIdentifier = category
        }
        if let iconPath = event.iconPath,
           let attachment = iconAttachment(for: iconPath, eventID: event.id) {
            content.attachments = [attachment]
        }
        // Reusing an identifier replaces the notification already on screen.
        return UNNotificationRequest(identifier: event.notificationID, content: content, trigger: nil)
    }

    /// Renders an app bundle's icon (or an image file) to a PNG attachment.
    /// UNNotificationAttachment moves the file into the notification store, so it is
    /// written to a per-event temp file.
    private func iconAttachment(for path: String, eventID: String) -> UNNotificationAttachment? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let image = path.hasSuffix(".app")
            ? NSWorkspace.shared.icon(forFile: path)
            : NSImage(contentsOfFile: path)
        guard let image, let png = pngData(from: image, pixels: 256) else { return nil }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(eventID).png")
        do {
            try png.write(to: url, options: .atomic)
            return try UNNotificationAttachment(identifier: "icon", url: url, options: nil)
        } catch {
            notifierLog.error("Icon attachment failed for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func pngData(from image: NSImage, pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        let size = NSSize(width: pixels, height: pixels)
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
