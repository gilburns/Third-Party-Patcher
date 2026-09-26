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

import Foundation

struct PatcherNotificationEvent: Codable {

    enum Kind: String, Codable {
        case quietApplyInstalled
    }

    let id: String
    let kind: Kind
    let created: Date
    let expires: Date
    let title: String
    let body: String
    /// Notification Center groups notifications sharing a thread ID.
    let threadID: String
    let playSound: Bool
    /// Path to a .app bundle or image file, rendered as the notification's icon attachment.
    let iconPath: String?
    let label: String?

    init(kind: Kind, title: String, body: String, threadID: String,
         playSound: Bool = false, iconPath: String? = nil, label: String? = nil,
         lifetime: TimeInterval = 24 * 60 * 60) {
        let now = Date()
        self.id        = UUID().uuidString
        self.kind      = kind
        self.created   = now
        self.expires   = now.addingTimeInterval(lifetime)
        self.title     = title
        self.body      = body
        self.threadID  = threadID
        self.playSound = playSound
        self.iconPath  = iconPath
        self.label     = label
    }

    var isExpired: Bool { expires < Date() }
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

    /// Deletes expired or unreadable events. Requires root; called by patcherscheduler.
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
        if removed > 0 {
            Logger.verbose("🔔 Pruned \(removed) expired notification event\(removed == 1 ? "" : "s").")
        }
    }
}
