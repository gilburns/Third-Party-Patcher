//
//  DialogSession.swift
//
//  A window PatcherNotifier shows on patcher's behalf. patcher (root) writes the whole
//  current state of each window to one file in the notification queue folder, rewriting
//  it on every change; PatcherNotifier (console user) draws whatever the file says.
//  Removing the file closes the window.
//
//  Prompts answer back through patcherscheduler: PatcherNotifier sends a DialogResponse
//  over XPC, the daemon records it as a small file, and the waiting patcher takes it.
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
        /// BlockingProcessAction = notify: the app needs to be quit; OK closes it.
        case blockingNotice
        /// BlockingProcessAction = prompt: Skip Update, or Quit <App> before the countdown ends.
        case blockingPrompt

        /// Kinds the user answers. PatcherNotifier reports when these are on screen and
        /// which button was clicked. (The apply window also asks, while `.choosing`.)
        var expectsResponse: Bool {
            switch self {
            case .blockingNotice, .blockingPrompt:      return true
            case .applyList, .applyCompact, .progress:  return false
            }
        }
    }

    enum Phase: String, Codable {
        /// The apply window before installing: the user picks which updates to install
        /// now, or defers them all. Install turns it into `.running` in place.
        case choosing
        case running
        /// Work has finished; the window stays until Done, `autoCloseAt`, or removal.
        case complete
    }

    struct Item: Codable, Equatable, Identifiable {
        enum Status: String, Codable {
            case pending, working, success, failed, skipped
            /// Choosing: ready to install, or blocked by a running app.
            case ready, blocked
            /// Deferred by the user in the choosing phase; not installed this run.
            case deferred
        }
        /// The Installomator label.
        let id: String
        var title: String
        /// "1.2 → 1.3" when both versions are known.
        var subtitle: String?
        var icon: String?
        var status: Status
        var statusText: String
        /// 0…1 while a working item reports how far along it is (download or install).
        /// nil shows a spinner.
        var progress: Double? = nil
        /// Choosing: whether the row's "install now" checkbox starts checked. nil: no
        /// checkbox (per-app deferral off, or the hard deadline).
        var selected: Bool? = nil
    }

    struct Progress: Codable, Equatable {
        var current: Int
        var total: Int
        var indeterminate: Bool
        var text: String
        /// 0…1 of the item now under way, added to `current` so the bar moves within an
        /// item. nil when the item doesn't report progress.
        var fraction: Double? = nil
    }

    struct Button: Codable, Equatable {
        var title: String
        var enabled: Bool
    }

    /// A countdown patcher is running. Shown only: patcher acts when it ends, not the agent.
    struct Countdown: Codable, Equatable {
        var ends: Date
        var seconds: Int
    }

    /// A dropdown whose choice is sent back with the primary button.
    struct Menu: Codable, Equatable {
        struct Option: Codable, Equatable {
            var value: String
            var label: String
        }
        var title: String
        var options: [Option]
        /// The `value` selected when the window opens.
        var selected: String
    }

    /// A checkbox. PatcherNotifier reports each change (`DialogResponse.toggled`), and
    /// sends its state with the secondary button.
    struct Checkbox: Codable, Equatable {
        var label: String
        var checked: Bool

        /// How a checkbox state travels as a response value.
        static func value(_ checked: Bool) -> String { checked ? "1" : "0" }
        static let values: Set<String> = ["0", "1"]
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
        /// Dark-mode versions of the two colors above; nil uses the light value in both.
        var textColorDarkHex: String? = nil
        var backgroundColorDarkHex: String? = nil
        /// The DialogIcon spec, for the compact window's header. It stays put while
        /// `icon` changes to the app being installed.
        var icon: String? = nil
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
    /// The apply window changes from `.applyList` to `.applyCompact` after the choosing
    /// phase when ApplyDialogSize = compact.
    var kind: Kind
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
    /// The default button (Return). For the apply window, Done.
    var button: Button?
    /// Drawn to the left of `button`. Prompts only.
    var secondaryButton: Button?
    var countdown: Countdown?
    var menu: Menu?
    var checkbox: Checkbox? = nil
    var help: Help?
    /// When set, the agent closes the window at this time if the user hasn't.
    var autoCloseAt: Date?

    var isExpired: Bool { expires < Date() }

    /// The user is being asked something: a prompt, or the apply window while choosing.
    /// PatcherNotifier reports when these are on screen, and patcher waits for the answer.
    var awaitsResponse: Bool { kind.expectsResponse || phase == .choosing }

    /// The row ids that offer a checkbox while choosing.
    var selectableIDs: Set<String> { Set(items.filter { $0.selected != nil }.map(\.id)) }
}

/// What the user picked in the apply window's choosing phase, sent with Install.
struct DialogChoice: Codable, Equatable {
    /// Rows the user unchecked.
    var deferred: [String]
    /// The "Defer for" menu value, when the window has the menu.
    var minutes: String?

    func encoded() -> String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static func decode(_ value: String) -> DialogChoice? {
        try? JSONDecoder().decode(DialogChoice.self, from: Data(value.utf8))
    }

    /// Only rows that offered a checkbox, and a menu value the window offered.
    func isValid(for session: DialogSession) -> Bool {
        guard Set(deferred).isSubset(of: session.selectableIDs) else { return false }
        if let minutes { return session.menu?.options.contains { $0.value == minutes } ?? false }
        return true
    }
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

    // MARK: Responses

    private static func responseURL(id: String, _ response: DialogResponse) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        return AppConstants.patcherNotificationResponseFolderURL
            .appendingPathComponent("\(id)-\(response.rawValue).\(responseExtension)")
    }

    static let responseExtension = "dialogresponse"

    /// The session with this id, if the user can answer it now: a running prompt, or the
    /// apply window while choosing.
    static func answerableSession(id: String) -> DialogSession? {
        guard let url = url(for: id),
              let session = try? decoder.decode(DialogSession.self, from: Data(contentsOf: url)),
              !session.isExpired, session.awaitsResponse, session.phase != .complete
        else { return nil }
        return session
    }

    /// Records a response, with the menu choice if there is one, for the patcher process
    /// waiting on it. Requires root; called by patcherscheduler's XPC handler. Stale files
    /// are pruned with notification responses.
    static func writeResponse(id: String, _ response: DialogResponse, value: String? = nil) -> Bool {
        guard let url = responseURL(id: id, response) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o755])
            try Data((value ?? "").utf8).write(to: url, options: .atomic)
            return true
        } catch {
            Logger.log("⚠️ Failed to record dialog response for \(id): \(error)")
            return false
        }
    }

    /// True (and consumed) when the response has been recorded.
    static func takeResponse(id: String, _ response: DialogResponse) -> Bool {
        takeResponseValue(id: id, response) != nil
    }

    /// The recorded response's menu value ("" when it has none), consumed; nil if not recorded.
    static func takeResponseValue(id: String, _ response: DialogResponse) -> String? {
        guard let url = responseURL(id: id, response),
              let data = FileManager.default.contents(atPath: url.path) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return String(decoding: data, as: UTF8.self)
    }

    /// Clears responses left for a session, so a reused id can't see old answers.
    static func removeResponses(id: String) {
        for response in DialogResponse.allCases {
            if let url = responseURL(id: id, response) { try? FileManager.default.removeItem(at: url) }
        }
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

/// What PatcherNotifier reports back for a session that expects a response.
enum DialogResponse: String, Codable, CaseIterable {
    /// The window is on screen. Until patcher has this, it never treats silence as consent.
    case displayed
    /// The default button: Skip Update, OK, or Install (with a DialogChoice) while choosing.
    case primary
    /// Quit <App> (with the checkbox state), or Defer All (with the menu value) while choosing.
    case secondary
    /// Closed without a button (the quit key).
    case dismissed
    /// The checkbox changed; the value is its new state. The window stays open.
    case toggled
}
