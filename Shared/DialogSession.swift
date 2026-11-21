//
//  DialogSession.swift
//
//  A window PatcherNotifier shows on patcher's behalf. patcher (root) writes the whole
//  current state of each window to one file in the notification queue folder, rewriting
//  it on every change; PatcherNotifier (console user) draws whatever the file says.
//  Removing the file closes the window.
//
//  Session files use the `.dialog` extension so UserNotificationQueue, which reads
//  `.json` files in the same folder, never sees them. The folder is already watched by
//  PatcherNotifier's LaunchAgent (WatchPaths), so writing a session launches the agent.
//

import Foundation

struct DialogSession: Codable, Equatable {

    enum Kind: String, Codable {
        /// The large apply window: one row per update, with a branded side panel.
        case applyList
        /// The compact apply window: one status line, updated in place.
        case applyCompact
        /// The small window for user-initiated scan / check / stage runs.
        case progress
    }

    enum Phase: String, Codable {
        case running
        /// Work has finished; the window stays until Done, `autoCloseAt`, or removal.
        case complete
    }

    struct Item: Codable, Equatable, Identifiable {
        enum Status: String, Codable {
            case pending, working, success, failed, skipped
        }
        /// The Installomator label.
        let id: String
        var title: String
        /// "1.2 → 1.3" when both versions are known.
        var subtitle: String?
        var icon: String?
        var status: Status
        var statusText: String
    }

    struct Progress: Codable, Equatable {
        var current: Int
        var total: Int
        var indeterminate: Bool
        var text: String
    }

    struct Button: Codable, Equatable {
        var title: String
        var enabled: Bool
    }

    struct WindowOptions: Codable, Equatable {
        /// topleft | left | bottomleft | top | center | bottom | topright | right | bottomright
        var position: String
        var onTop: Bool
        var movable: Bool
        var blurScreen: Bool
        var hideOtherApps: Bool
        /// Any of "close", "min", "max".
        var buttons: [String]
    }

    struct Branding: Codable, Equatable {
        var appTitle: String
        /// Six-digit hex, no "#".
        var textColorHex: String
        var backgroundColorHex: String
    }

    struct Help: Codable, Equatable {
        struct Row: Codable, Equatable {
            var label: String
            var value: String
            /// Opened when the value is clicked (website rows).
            var link: String?
        }
        var supportTeamName: String
        var contact: [Row]
        var computer: [Row]
        var software: [Row]
    }

    let id: String
    let kind: Kind
    /// Only the agent running for this user shows the window.
    let consoleUID: UInt32
    /// The patcher process writing the session. A running session whose owner has
    /// exited is stale (patcher crashed or was killed) and is not shown.
    let ownerPID: Int32
    let created: Date
    /// Pushed forward on every write; the scheduler prunes sessions past it.
    var expires: Date
    var revision: Int
    var phase: Phase

    var window: WindowOptions
    var branding: Branding
    /// Icon specs: a file path (image or .app), an http(s) URL, a built-in name
    /// (caution, info, stop, computer), or an SF Symbol spec ("SF=name,weight=…,palette=…").
    var icon: String?
    var overlayIcon: String?
    var title: String
    /// Inline Markdown (bold, italic, links). Newlines are kept.
    var message: String
    /// Inline Markdown for the large window's branded side panel.
    var sidePanel: String?
    var items: [Item]
    var progress: Progress
    var button: Button?
    var help: Help?
    /// When set, the agent closes the window at this time if the user hasn't.
    var autoCloseAt: Date?

    var isExpired: Bool { expires < Date() }
}

enum DialogSessionStore {

    static let fileExtension = "dialog"

    /// How long a session lives without being rewritten. Long enough for a slow install,
    /// short enough that a session orphaned by a crash doesn't linger for long.
    static let lifetime: TimeInterval = 3 * 60 * 60

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

    private static func url(for id: String) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        return folderURL.appendingPathComponent("\(id).\(fileExtension)")
    }

    private static func sessionFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == fileExtension }
    }

    /// Writes the session atomically (root:wheel 0644). Requires root.
    @discardableResult
    static func write(_ session: DialogSession) -> Bool {
        guard let url = url(for: session.id) else { return false }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folderURL, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o755])
            try encoder.encode(session).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            return true
        } catch {
            Logger.log("⚠️ Failed to write dialog session \(session.id): \(error)")
            return false
        }
    }

    /// Removes the session, closing its window. Requires root.
    static func remove(id: String) {
        guard let url = url(for: id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes every session of the given kinds. A new run calls this first so a window
    /// left behind by an earlier run (finished or crashed) doesn't sit alongside the new one.
    static func removeAll(kinds: Set<DialogSession.Kind>) {
        for url in sessionFiles() {
            let session = try? decoder.decode(DialogSession.self, from: Data(contentsOf: url))
            if let session, !kinds.contains(session.kind) { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// All readable, unexpired sessions.
    static func activeSessions() -> [DialogSession] {
        sessionFiles()
            .compactMap { try? decoder.decode(DialogSession.self, from: Data(contentsOf: $0)) }
            .filter { !$0.isExpired }
    }

    /// Deletes expired or unreadable sessions. Requires root; called by patcherscheduler.
    static func pruneExpired() {
        var removed = 0
        for url in sessionFiles() {
            let session = try? decoder.decode(DialogSession.self, from: Data(contentsOf: url))
            if session?.isExpired ?? true, (try? FileManager.default.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        if removed > 0 {
            Logger.verbose("🪟 Pruned \(removed) expired dialog session\(removed == 1 ? "" : "s").")
        }
    }
}
