//
//  PresenterTypes.swift
//  patcher
//
//  Types shared by every user-facing presenter (see ApplyPresenter.swift). None of
//  these depend on how the UI is drawn, so they outlive any one implementation.
//

import Foundation

// MARK: - Apply items

/// One update shown to the user during the deferral prompt and the apply phase.
struct ApplyItem {
    let label:            String
    let displayName:      String
    let iconPath:         String?
    let installedVersion: String?
    let newVersion:       String?
    let isBlocked:        Bool

    init(label: String, displayName: String, iconPath: String? = nil, installedVersion: String? = nil, newVersion: String? = nil, isBlocked: Bool = false) {
        self.label            = label
        self.displayName      = displayName
        self.iconPath         = iconPath
        self.installedVersion = installedVersion
        self.newVersion       = newVersion
        self.isBlocked        = isBlocked
    }
}

// MARK: - Blocking processes

/// Blocking-process actions (set via BlockingProcessAction preference):
///   ignore — skip the blocking-process check; install immediately
///   kill   — force-quit the blocking process silently; install
///   notify — tell the user the app needs to be quit; skip the label
///   prompt — ask the user to quit, with a countdown; on expiry or "Quit App",
///            force-quit and install; "Skip" defers
///   defer  — skip the label silently this cycle (no UI)
enum BlockingProcessAction {
    case ignore, kill, notify, prompt, defer_

    init(rawValue: String) {
        switch rawValue.lowercased() {
        case "ignore": self = .ignore
        case "kill":   self = .kill
        case "notify": self = .notify
        case "defer":  self = .defer_
        default:       self = .prompt
        }
    }
}

enum BlockingActionResponse {
    case proceed         // blocker was quit; install can continue (no relaunch)
    case proceedRelaunch // blocker was quit; reopen it after the install
    case skip            // user or policy chose to skip this label
}

// MARK: - Apply window style

/// Size/style of the apply-phase progress window. A string-backed preference
/// (ApplyDialogSize) selects this so additional sizes can be added later
/// without introducing a new preference key.
enum ApplyDialogSize: Equatable {
    case large, compact
    /// No window — see NotificationApplyPresenter.
    case notifications

    init(rawValue: String) {
        switch rawValue.lowercased() {
        case "compact":       self = .compact
        case "notifications": self = .notifications
        default:              self = .large
        }
    }
}

// MARK: - Deferral

enum DeferralPromptResult {
    case proceed                         // user installed everything now
    case partial(deferred: [String], minutes: Int) // user unchecked these apps; install the rest now
    case deferred(minutes: Int)          // user explicitly clicked Defer All
    case timedOutDeferred(minutes: Int)  // countdown timer expired; auto-deferred
    case deadlineForced                  // hard deadline reached; proceeded without user choice
}

enum DeferralMenu {
    /// The menu's default must be one of the menu values, or there is nothing to
    /// pre-select and a timed-out prompt would defer longer than the menu allows (e.g. on a
    /// capped patch day). Falls back to the longest option not exceeding the configured
    /// default, else the shortest option.
    static func effectiveDefault(_ configured: Int, menu: [Int]) -> Int {
        guard !menu.isEmpty, !menu.contains(configured) else { return configured }
        return menu.last { $0 <= configured } ?? menu[0]
    }
}
