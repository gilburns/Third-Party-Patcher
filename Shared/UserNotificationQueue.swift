//
//  UserNotificationQueue.swift
//
//  File-based queue between patcher (root, writer) and PatcherNotifier
//  (console user, reader). Each event is one JSON file in
//  AppConstants.patcherNotificationQueueFolderURL; PatcherNotifier's LaunchAgent
//  watches that folder and posts the events to Notification Center.
//
//  Files are root-owned and world-readable. PatcherNotifier never deletes them —
//  it tracks delivered IDs in its own defaults. patcherscheduler prunes expired events.
//
//  Actionable notifications (blocking-app prompts) flow back the other way:
//  PatcherNotifier → XPC → patcherscheduler writes a response file →
//  the waiting patcher process consumes it (see takeResponse).
//

import Foundation

struct PatcherNotificationEvent: Codable {

    enum Kind: String, Codable {
        case quietApplyInstalled
        /// Notification-mode apply (ApplyDialogSize = notifications):
        case applyInProgress
        case applyInstalled
        case applyFailed
        case blockingNotify    // informational: quit the app when convenient
        case blockingPrompt    // actionable: Quit & Update, or dismiss to skip
        /// Removes the delivered notification identified by `replaceID`.
        case withdraw
    }

    /// Category registered by PatcherNotifier for blocking-app prompts.
    static let blockingPromptCategory = "blockingPrompt"

    let id: String
    let kind: Kind
    let created: Date
    let expires: Date
    let title: String
    /// The admin's AppTitle, shown as the notification's title with `title` moved
    /// to the subtitle line. nil when AppTitle is left at its default.
    let brandTitle: String?
    let body: String
    /// Notification Center groups notifications sharing a thread ID.
    let threadID: String
    let playSound: Bool
    /// Path to a .app bundle or image file, rendered as the notification's icon attachment.
    let iconPath: String?
    let label: String?
    /// Notification Center identifier. Events sharing a replaceID replace each other's
    /// delivered notification (e.g. prompt → "Updating…" → "Updated"). nil = use `id`.
    let replaceID: String?
    /// Notification category, for events that carry action buttons.
    let category: String?

    init(kind: Kind, title: String, body: String, threadID: String,
         playSound: Bool = false, iconPath: String? = nil, label: String? = nil,
         replaceID: String? = nil, category: String? = nil,
         lifetime: TimeInterval = 24 * 60 * 60) {
        let now = Date()
        self.id        = UUID().uuidString
        self.kind      = kind
        self.created   = now
        self.expires   = now.addingTimeInterval(lifetime)
        self.title     = title
        self.brandTitle = kind == .withdraw ? nil : Self.customAppTitle()
        self.body      = body
        self.threadID  = threadID
        self.playSound = playSound
        self.iconPath  = iconPath
        self.label     = label
        self.replaceID = replaceID
        self.category  = category
    }

    /// A withdraw event removing the delivered notification with the given identifier.
    static func withdraw(replaceID: String) -> PatcherNotificationEvent {
        PatcherNotificationEvent(kind: .withdraw, title: "", body: "", threadID: "",
                                 replaceID: replaceID, lifetime: 60 * 60)
    }

    /// The admin's AppTitle, or nil when it is empty or left at the default —
    /// the default name adds nothing beside the PatcherNotifier header.
    private static func customAppTitle() -> String? {
        let appTitle = Preferences().appTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appTitle.isEmpty, appTitle != Preferences.defaultAppTitle else { return nil }
        return appTitle
    }

    /// The identifier used for the Notification Center request.
    var notificationID: String { replaceID ?? id }

    var isExpired: Bool { expires < Date() }
}

/// A user's answer to an actionable notification.
enum NotificationResponseAction: String, Codable {
    case quitAndUpdate
    case skip
}

struct PatcherNotificationResponse: Codable {
    let eventID: String
    let action: NotificationResponseAction
    let date: Date
}

enum UserNotificationQueue {

    static var folderURL: URL { AppConstants.patcherNotificationQueueFolderURL }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Writes an event to the queue. Filenames sort chronologically.
    static func enqueue(_ event: PatcherNotificationEvent) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folderURL, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o755])
            let millis = Int(event.created.timeIntervalSince1970 * 1000)
            let url = folderURL.appendingPathComponent("\(millis)-\(event.id).json")
            try encoder.encode(event).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            Logger.log("🔔 Notification queued: \(event.title) — \(event.body)")
        } catch {
            Logger.log("⚠️ Failed to queue notification '\(event.title)': \(error)")
        }
    }

    /// Returns all readable, unexpired events, oldest first.
    static func pendingEvents() -> [PatcherNotificationEvent] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? decoder.decode(PatcherNotificationEvent.self, from: Data(contentsOf: $0)) }
            .filter { !$0.isExpired }
    }

    /// Returns the unexpired event with the given id, if still queued.
    static func event(withID id: String) -> PatcherNotificationEvent? {
        guard UUID(uuidString: id) != nil else { return nil }
        let files = (try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? []
        guard let url = files.first(where: { $0.lastPathComponent.hasSuffix("-\(id).json") }),
              let event = try? decoder.decode(PatcherNotificationEvent.self, from: Data(contentsOf: url)),
              !event.isExpired
        else { return nil }
        return event
    }

    // MARK: - Responses

    static var responseFolderURL: URL { AppConstants.patcherNotificationResponseFolderURL }

    private static func responseURL(eventID: String) -> URL? {
        guard UUID(uuidString: eventID) != nil else { return nil }
        return responseFolderURL.appendingPathComponent("\(eventID).json")
    }

    /// Records a response for the patcher process waiting on it. Requires root; called by
    /// patcherscheduler's XPC handler.
    static func writeResponse(_ response: PatcherNotificationResponse) -> Bool {
        guard let url = responseURL(eventID: response.eventID) else { return false }
        do {
            try FileManager.default.createDirectory(at: responseFolderURL, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o755])
            try encoder.encode(response).write(to: url, options: .atomic)
            return true
        } catch {
            Logger.log("⚠️ Failed to record notification response for \(response.eventID): \(error)")
            return false
        }
    }

    /// Returns and deletes the response for an event, if one has been recorded.
    static func takeResponse(eventID: String) -> NotificationResponseAction? {
        guard let url = responseURL(eventID: eventID),
              let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return (try? decoder.decode(PatcherNotificationResponse.self, from: data))?.action
    }

    /// Deletes expired or unreadable events, and responses nobody consumed.
    /// Requires root; called by patcherscheduler.
    static func pruneExpired() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        for url in files where url.pathExtension == "json" {
            let event = try? decoder.decode(PatcherNotificationEvent.self, from: Data(contentsOf: url))
            if event?.isExpired ?? true {
                if (try? fm.removeItem(at: url)) != nil { removed += 1 }
            }
        }
        // A response is consumed within seconds by the waiting patcher; anything left
        // over belongs to a run that has already ended.
        let staleCutoff = Date().addingTimeInterval(-60 * 60)
        let responses = (try? fm.contentsOfDirectory(at: responseFolderURL, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in responses {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < staleCutoff, (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        if removed > 0 {
            Logger.verbose("🔔 Pruned \(removed) expired notification file\(removed == 1 ? "" : "s").")
        }
    }
}
