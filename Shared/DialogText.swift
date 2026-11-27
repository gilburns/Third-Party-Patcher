//
//  DialogText.swift
//
//  Text patcher sends to PatcherNotifier as typed values instead of finished English.
//  patcher (root, no app bundle) can't know the console user's language, so a session
//  carries what to say (a message and its values) and PatcherNotifier words it in the
//  user's language. Code also compares these values, never displayed text.
//
//  Translations live in PatcherNotifier's "Dialogs" table. Apps that show the same text
//  (Available Software's live status) read it from PatcherNotifier.app; patcher reads the
//  app's English table, so the text it logs is English.
//
//  Keys with a count are written in their plural form ("There are **%lld updates**
//  waiting."); the catalog's English plural variations supply the singular.
//

import Foundation

/// A message for the user. Cases carry values, not words; `text` words them.
///
/// A message is one whole sentence (or label), or a list of whole sentences joined by
/// `sentences` / `paragraphs`: never pieces of one sentence, which a translator couldn't
/// reorder. Strings with Markdown keep it; PatcherNotifier renders it.
indirect enum DialogText: Codable, Equatable {

    // MARK: Building blocks

    /// Shown as-is: app names and admin-supplied text.
    case verbatim(String)
    /// Progress of the step now running.
    case progress(ProgressDetail)
    /// Why an item was skipped (or paused).
    case skipped(SkipReason)
    /// Whole paragraphs, separated by blank lines.
    case paragraphs([DialogText])
    /// Whole sentences in one paragraph, separated by spaces.
    case sentences([DialogText])
    /// "Update 2 of 5 · Installing 45%": a step and its detail.
    case withDetail(DialogText, DialogText)
    /// "1 hour, 30 minutes".
    case duration(minutes: Int)
    /// "1 hr, 30 min": for tight spots such as the deferral menu.
    case shortDuration(minutes: Int)
    /// A date and time, in the reader's format.
    case date(Date)

    // MARK: Apply window

    /// "There are **3 updates** waiting."
    case updatesWaiting(count: Int)
    case updatesBeingAttempted
    /// "Zoom and Slack are deferred for 2 hours."
    case appsDeferred(names: [String], minutes: Int)
    case preparing
    /// The disabled button while installing.
    case updating
    /// "Update 2 of 5"
    case updateOfTotal(current: Int, total: Int)
    /// "Update 2 of 5 - Installing: Zoom…"
    case updateOfTotalInstalling(current: Int, total: Int, app: String)
    /// "Installing: Zoom → 6.1…"
    case installingApp(app: String, version: String?)
    case updated
    case failed
    /// "✅ Updated: Zoom → 6.1"
    case updatedApp(app: String, version: String?)
    /// "❌ Failed: Zoom → 6.1"
    case failedApp(app: String, version: String?)
    /// "⚠️ Zoom — App running"
    case skippedApp(app: String, reason: SkipReason)
    /// "Complete — 3 updated · 1 skipped"
    case completeSummary(applied: Int, skipped: Int, failed: Int)
    case allUpdatesApplied
    case updatesJustAttempted
    /// Side-panel note when an app was skipped because another user has it open.
    case skippedForAnotherUser
    case done
    /// "Waiting for user — Zoom"
    case waitingForUserApp(String)
    /// "Shutdown — stopping after 2 items"
    case shutdownStopping(applied: Int)

    // MARK: Choosing (the deferral prompt)

    /// "You have **3 software updates** ready to install."
    case readyToInstall(count: Int)
    case uncheckToPutOff
    /// "They have been pending for **4 days**."
    case pendingForDays(count: Int, days: Int)
    case installationRequired
    /// The side panel's deferral counts, and the hard deadline when there is one.
    case deferralStatus(daysPending: Int, userDeferrals: Int, autoDeferrals: Int, deadline: Date? = nil)
    /// Side panel badge: "**2 days** left to defer".
    case deadlineDaysLeft(days: Int)
    /// Side panel badge: "**5 hours** left to defer".
    case deadlineHoursLeft(hours: Int)
    case deadlineUnderAnHour
    case deadlinePassed
    case openWillAskToQuit
    case ready
    case installNow
    case installAllNow
    /// "Defer (2 hours)": the button when there is no "Defer for" menu.
    case deferForDuration(minutes: Int)
    case deferOne
    case deferAll
    /// The "Defer for" menu's title.
    case deferForMenu
    /// "Deferred · 2 hours": a row the user deferred.
    case deferredFor(minutes: Int)
    case waiting

    // MARK: Help

    case phone, email, website, computerName, serialNumber, started

    // MARK: Progress window (scan / check / download)

    /// "2 of 5"
    case countOfTotal(current: Int, total: Int)
    case processCompleted
    case complete
    case scanningApps(count: Int)
    /// "Scanning zoom…" (an Installomator label)
    case scanningLabel(String)
    /// "Scanning…": Available Software's status line while a self-service install scans.
    case scanning
    case checkingApps(count: Int)
    /// "Checking: **Zoom** for updates…"
    case checkingApp(String)
    case downloadingUpdates(count: Int)
    /// "Downloading: **Zoom**…"
    case downloadingApp(String)
    case labelsUnavailable
    case noUpdatesAvailable
    case updatesAvailableToDownload(count: Int)
    case updatesReadyToInstall(count: Int)
    case updatesStillWaitingToDownload(count: Int)
    case noMoreToDownload

    // MARK: Blocking-app notice and prompt

    /// "Update Pending: Zoom"
    case updatePendingTitle(app: String)
    case quitWhenConvenient(app: String)
    case ok
    /// "Zoom Update Paused"
    case updatePausedTitle(app: String)
    case needsUpdateButRunning(app: String, process: String)
    case saveAndQuitOrSkip(process: String)
    case skipUpdate
    /// "Quit Zoom"
    case quitApp(process: String)
    case reopenAfterUpdate(app: String)

    // MARK: Notifications (ApplyDialogSize = notifications, and quiet installs)

    /// "Updating Zoom"
    case updatingAppTitle(app: String)
    case appBeingUpdated(app: String)
    /// "Zoom Couldn't Be Updated"
    case appUpdateFailedTitle(app: String)
    case updateWillBeRetried(app: String)
    /// "Zoom Update Ready"
    case appUpdateReadyTitle(app: String)
    /// The Quit & Update notification's body, with the seconds until the app is quit.
    case quitAndUpdatePrompt(process: String, seconds: Int)
    /// "Zoom Updated"
    case appUpdatedTitle(app: String)
    /// "Zoom was updated to version 1.2 in the background." `version` nil when unknown.
    case appWasUpdated(app: String, version: String?, background: Bool)
    /// "3 Apps Updated"
    case appsUpdatedTitle(count: Int)
    /// "Zoom 6.1, Slack 4.4, and Firefox".
    case appList([String])

    /// The message in the reader's language.
    var text: String {
        let b = Bundle.dialogStrings
        switch self {

        case .verbatim(let string):     return string
        case .progress(let detail):     return detail.text
        case .skipped(let reason):      return reason.text
        case .paragraphs(let parts):    return parts.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        case .sentences(let parts):     return parts.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        case .withDetail(let step, let detail):
            let stepText = step.text, detailText = detail.text
            return String(localized: "\(stepText) · \(detailText)", table: "Dialogs", bundle: b,
                          comment: "A progress step and its detail, e.g. “Update 2 of 5 · Installing 45%”")
        case .duration(let minutes):
            return Duration.seconds(max(minutes, 0) * 60)
                .formatted(.units(allowed: [.hours, .minutes], width: .wide))
        case .shortDuration(let minutes):
            return Duration.seconds(max(minutes, 0) * 60)
                .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        case .date(let date):
            return date.formatted(date: .abbreviated, time: .shortened)

        // Apply window
        case .updatesWaiting(let count):
            return String(localized: "There are **\(count) updates** waiting.", table: "Dialogs", bundle: b,
                          comment: "Apply window: how many updates will be installed")
        case .updatesBeingAttempted:
            return String(localized: "These updates are being attempted.", table: "Dialogs", bundle: b,
                          comment: "Apply window side panel while installing")
        case .appsDeferred(let names, let minutes):
            let list = names.formatted(.list(type: .and))
            let duration = DialogText.duration(minutes: minutes).text
            if names.count == 1 {
                return String(localized: "\(list) is deferred for \(duration).", table: "Dialogs", bundle: b,
                              comment: "Apply window side panel: one app the user deferred, and for how long")
            }
            return String(localized: "\(list) are deferred for \(duration).", table: "Dialogs", bundle: b,
                          comment: "Apply window side panel: a list of apps the user deferred (“Zoom and Slack”), and for how long")
        case .preparing:
            return String(localized: "Preparing…", table: "Dialogs", bundle: b,
                          comment: "Apply window caption before the first install starts")
        case .updating:
            return String(localized: "Updating…", table: "Dialogs", bundle: b,
                          comment: "Apply window: the disabled button while updates install")
        case .updateOfTotal(let current, let total):
            return String(localized: "Update \(current) of \(total)", table: "Dialogs", bundle: b,
                          comment: "Compact apply window caption: which update is installing")
        case .updateOfTotalInstalling(let current, let total, let app):
            return String(localized: "Update \(current) of \(total) - Installing: \(app)…", table: "Dialogs", bundle: b,
                          comment: "Apply window caption: which update is installing, and the app")
        case .installingApp(let app, let version):
            if let version, !version.isEmpty {
                return String(localized: "Installing: \(app) → \(version)…", table: "Dialogs", bundle: b,
                              comment: "Compact apply window: the app installing and its new version")
            }
            return String(localized: "Installing: \(app)…", table: "Dialogs", bundle: b,
                          comment: "Compact apply window: the app installing")
        case .updated:
            return String(localized: "Updated", table: "Dialogs", bundle: b,
                          comment: "Apply window row: the update installed")
        case .failed:
            return String(localized: "Failed", table: "Dialogs", bundle: b,
                          comment: "Apply window row: the update failed to install")
        case .updatedApp(let app, let version):
            if let version, !version.isEmpty {
                return String(localized: "✅ Updated: \(app) → \(version)", table: "Dialogs", bundle: b,
                              comment: "Compact apply window: the app updated, and its new version")
            }
            return String(localized: "✅ Updated: \(app)", table: "Dialogs", bundle: b,
                          comment: "Compact apply window: the app updated")
        case .failedApp(let app, let version):
            if let version, !version.isEmpty {
                return String(localized: "❌ Failed: \(app) → \(version)", table: "Dialogs", bundle: b,
                              comment: "Compact apply window: the app's update failed, and the version it tried")
            }
            return String(localized: "❌ Failed: \(app)", table: "Dialogs", bundle: b,
                          comment: "Compact apply window: the app's update failed")
        case .skippedApp(let app, let reason):
            let reasonText = reason.text
            return String(localized: "⚠️ \(app) — \(reasonText)", table: "Dialogs", bundle: b,
                          comment: "Compact apply window: the app was skipped, and why")
        case .completeSummary(let applied, let skipped, let failed):
            let summary: String
            if failed > 0 {
                summary = String(localized: "\(applied) updated · \(skipped) skipped · \(failed) failed", table: "Dialogs", bundle: b,
                                 comment: "Apply window result counts")
            } else if skipped > 0 {
                summary = String(localized: "\(applied) updated · \(skipped) skipped", table: "Dialogs", bundle: b,
                                 comment: "Apply window result counts")
            } else {
                summary = String(localized: "\(applied) updates applied successfully", table: "Dialogs", bundle: b,
                                 comment: "Apply window result: every update installed")
            }
            return String(localized: "Complete — \(summary)", table: "Dialogs", bundle: b,
                          comment: "Apply window caption when finished, followed by the result counts")
        case .allUpdatesApplied:
            return String(localized: "**All possible updates have been applied.**", table: "Dialogs", bundle: b,
                          comment: "Apply window when finished")
        case .updatesJustAttempted:
            return String(localized: "These updates were just attempted.", table: "Dialogs", bundle: b,
                          comment: "Apply window side panel when finished")
        case .skippedForAnotherUser:
            return String(localized: "Apps marked “In use by another user” are open in another account on this Mac, so they don't appear in your Dock. They'll be updated after they're quit in that account.", table: "Dialogs", bundle: b,
                          comment: "Apply window side panel when finished, shown when an app was skipped because another user on this Mac has it open")
        case .done:
            return String(localized: "Done", table: "Dialogs", bundle: b,
                          comment: "Apply window: the button that closes it when finished")
        case .waitingForUserApp(let app):
            return String(localized: "Waiting for user — \(app)", table: "Dialogs", bundle: b,
                          comment: "Apply window caption while a prompt asks the user to quit the app")
        case .shutdownStopping(let applied):
            return String(localized: "Shutdown — stopping after \(applied) items", table: "Dialogs", bundle: b,
                          comment: "Apply window caption: the Mac is shutting down; how many items were installed")

        // Choosing
        case .readyToInstall(let count):
            return String(localized: "You have **\(count) software updates** ready to install.", table: "Dialogs", bundle: b,
                          comment: "Deferral prompt: how many updates are ready")
        case .uncheckToPutOff:
            return String(localized: "Uncheck any you’d like to put off.", table: "Dialogs", bundle: b,
                          comment: "Deferral prompt: each app has an “install now” checkbox")
        case .pendingForDays(let count, let days):
            if count == 1 {
                return String(localized: "It has been pending for **\(days) days**.", table: "Dialogs", bundle: b,
                              comment: "Deferral prompt: how long one update has waited")
            }
            return String(localized: "They have been pending for **\(days) days**.", table: "Dialogs", bundle: b,
                          comment: "Deferral prompt: how long the updates have waited")
        case .installationRequired:
            return String(localized: "**Installation is required** — the maximum deferral deadline has been reached.",
                          table: "Dialogs", bundle: b,
                          comment: "Deferral prompt: the user can no longer defer")
        case .deferralStatus(let days, let user, let auto, let deadline):
            guard let deadline else {
                return String(localized: "**Deferral Status**\nDays pending: \(days)\nUser deferrals: \(user)\nAuto deferrals: \(auto)",
                              table: "Dialogs", bundle: b,
                              comment: "Deferral prompt side panel: a heading, then three counts on their own lines")
            }
            let when = deadline.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
            return String(localized: "**Deferral Status**\nDays pending: \(days)\nUser deferrals: \(user)\nAuto deferrals: \(auto)\n\n**Deadline**\n\(when)",
                          table: "Dialogs", bundle: b,
                          comment: "Deferral prompt side panel: a heading and three counts on their own lines; then, after a blank line, a second heading and when installation becomes required (a date and time such as “Thu, Nov 26, 9:14 AM”)")
        case .deadlineDaysLeft(let days):
            return String(localized: "**\(days) days** left to defer", table: "Dialogs", bundle: b,
                          comment: "Deferral prompt side panel badge: whole days until installation is required")
        case .deadlineHoursLeft(let hours):
            return String(localized: "**\(hours) hours** left to defer", table: "Dialogs", bundle: b,
                          comment: "Deferral prompt side panel badge: hours until installation is required (under a day)")
        case .deadlineUnderAnHour:
            return String(localized: "**Less than an hour** left to defer", table: "Dialogs", bundle: b,
                          comment: "Deferral prompt side panel badge: installation is required within the hour")
        case .deadlinePassed:
            return String(localized: "**Deferral deadline passed**", table: "Dialogs", bundle: b,
                          comment: "Deferral prompt side panel badge: the user can no longer defer")
        case .openWillAskToQuit:
            return String(localized: "Open — will ask to quit", table: "Dialogs", bundle: b,
                          comment: "Deferral prompt row: the app is running and will be asked to quit before updating")
        case .ready:
            return String(localized: "Ready", table: "Dialogs", bundle: b,
                          comment: "Deferral prompt row: ready to install")
        case .installNow:
            return String(localized: "Install Now", table: "Dialogs", bundle: b,
                          comment: "Deferral prompt button")
        case .installAllNow:
            return String(localized: "Install All Now", table: "Dialogs", bundle: b,
                          comment: "Deferral prompt button")
        case .deferForDuration(let minutes):
            let duration = DialogText.duration(minutes: minutes).text
            return String(localized: "Defer (\(duration))", table: "Dialogs", bundle: b,
                          comment: "Deferral prompt button, with how long it defers")
        case .deferOne:
            return String(localized: "Defer", table: "Dialogs", bundle: b,
                          comment: "Deferral prompt button (one update)")
        case .deferAll:
            return String(localized: "Defer All", table: "Dialogs", bundle: b,
                          comment: "Deferral prompt button (several updates)")
        case .deferForMenu:
            return String(localized: "Defer for", table: "Dialogs", bundle: b,
                          comment: "Deferral prompt: label of the menu of deferral lengths")
        case .deferredFor(let minutes):
            let duration = DialogText.duration(minutes: minutes).text
            return String(localized: "Deferred · \(duration)", table: "Dialogs", bundle: b,
                          comment: "Apply window row: the user deferred this app, and for how long")
        case .waiting:
            return String(localized: "Waiting", table: "Dialogs", bundle: b,
                          comment: "Apply window row: not started yet")

        // Help
        case .phone:
            return String(localized: "Phone", table: "Dialogs", bundle: b, comment: "Help popover: support phone number label")
        case .email:
            return String(localized: "Email", table: "Dialogs", bundle: b, comment: "Help popover: support email label")
        case .website:
            return String(localized: "Website", table: "Dialogs", bundle: b, comment: "Help popover: support website label")
        case .computerName:
            return String(localized: "Computer Name", table: "Dialogs", bundle: b, comment: "Help popover label")
        case .serialNumber:
            return String(localized: "Serial Number", table: "Dialogs", bundle: b, comment: "Help popover label")
        case .started:
            return String(localized: "Started", table: "Dialogs", bundle: b, comment: "Help popover: when the update run started")

        // Progress window
        case .countOfTotal(let current, let total):
            return String(localized: "\(current) of \(total)", table: "Dialogs", bundle: b,
                          comment: "Progress window caption: items done of the total")
        case .processCompleted:
            return String(localized: "Process completed", table: "Dialogs", bundle: b,
                          comment: "Progress window, just before it closes")
        case .complete:
            return String(localized: "Complete", table: "Dialogs", bundle: b,
                          comment: "Progress window caption when finished")
        case .scanningApps(let count):
            return String(localized: "Scanning \(count) applications for available updates…", table: "Dialogs", bundle: b,
                          comment: "Progress window: a scan started from PatcherMenu")
        case .scanningLabel(let label):
            return String(localized: "Scanning \(label)…", table: "Dialogs", bundle: b,
                          comment: "Progress window: the item being scanned (an Installomator label name)")
        case .scanning:
            return String(localized: "Scanning…", table: "Dialogs", bundle: b,
                          comment: "Available Software status line: checking the app before installing it")
        case .checkingApps(let count):
            return String(localized: "Checking \(count) applications for available updates…", table: "Dialogs", bundle: b,
                          comment: "Progress window: an update check started from PatcherMenu")
        case .checkingApp(let app):
            return String(localized: "Checking: **\(app)** for updates…", table: "Dialogs", bundle: b,
                          comment: "Progress window: the app being checked")
        case .downloadingUpdates(let count):
            return String(localized: "Downloading \(count) updates…", table: "Dialogs", bundle: b,
                          comment: "Progress window: downloads started from PatcherMenu")
        case .downloadingApp(let app):
            return String(localized: "Downloading: **\(app)**…", table: "Dialogs", bundle: b,
                          comment: "Progress window: the app being downloaded")
        case .labelsUnavailable:
            return String(localized: "Unable to scan — application labels could not be downloaded. The scan will retry automatically.",
                          table: "Dialogs", bundle: b, comment: "Progress window: the scan could not run")
        case .noUpdatesAvailable:
            return String(localized: "No updates available.", table: "Dialogs", bundle: b,
                          comment: "Progress window result")
        case .updatesAvailableToDownload(let count):
            return String(localized: "\(count) updates available to download.", table: "Dialogs", bundle: b,
                          comment: "Progress window result")
        case .updatesReadyToInstall(let count):
            return String(localized: "\(count) updates ready to install.", table: "Dialogs", bundle: b,
                          comment: "Progress window result after downloading")
        case .updatesStillWaitingToDownload(let count):
            return String(localized: "\(count) updates still waiting to download.", table: "Dialogs", bundle: b,
                          comment: "Progress window result after downloading")
        case .noMoreToDownload:
            return String(localized: "No more items to download.", table: "Dialogs", bundle: b,
                          comment: "Progress window result after downloading")

        // Blocking-app notice and prompt
        case .updatePendingTitle(let app):
            return String(localized: "Update Pending: \(app)", table: "Dialogs", bundle: b,
                          comment: "Notice title: the app must be quit before it can update")
        case .quitWhenConvenient(let app):
            return String(localized: "\(app) needs to be quit to apply an update. Please close it when convenient.",
                          table: "Dialogs", bundle: b, comment: "Notice message")
        case .ok:
            return String(localized: "OK", table: "Dialogs", bundle: b, comment: "Notice button")
        case .updatePausedTitle(let app):
            return String(localized: "\(app) Update Paused", table: "Dialogs", bundle: b,
                          comment: "Prompt title: the app is running, so its update is waiting")
        case .needsUpdateButRunning(let app, let process):
            return String(localized: "\(app) needs to be updated, but **\(process)** is currently running.",
                          table: "Dialogs", bundle: b,
                          comment: "Prompt message: the app to update, then the running process blocking it")
        case .saveAndQuitOrSkip(let process):
            return String(localized: "Please save your work and quit \(process) before the timer expires, or click **Skip Update** to postpone this update.",
                          table: "Dialogs", bundle: b,
                          comment: "Prompt message; “Skip Update” is the button's title")
        case .skipUpdate:
            return String(localized: "Skip Update", table: "Dialogs", bundle: b, comment: "Prompt button")
        case .quitApp(let process):
            return String(localized: "Quit \(process)", table: "Dialogs", bundle: b,
                          comment: "Prompt button: force-quits the running app")
        case .reopenAfterUpdate(let app):
            return String(localized: "Reopen \(app) after the update", table: "Dialogs", bundle: b,
                          comment: "Prompt checkbox")

        // Notifications
        case .updatingAppTitle(let app):
            return String(localized: "Updating \(app)", table: "Dialogs", bundle: b,
                          comment: "Notification title: the app is being updated now")
        case .appBeingUpdated(let app):
            return String(localized: "\(app) is being updated…", table: "Dialogs", bundle: b,
                          comment: "Notification body")
        case .appUpdateFailedTitle(let app):
            return String(localized: "\(app) Couldn't Be Updated", table: "Dialogs", bundle: b,
                          comment: "Notification title")
        case .updateWillBeRetried(let app):
            return String(localized: "The update for \(app) will be tried again later.", table: "Dialogs", bundle: b,
                          comment: "Notification body after a failed update")
        case .appUpdateReadyTitle(let app):
            return String(localized: "\(app) Update Ready", table: "Dialogs", bundle: b,
                          comment: "Notification title: the app must quit for its update")
        case .quitAndUpdatePrompt(let process, let seconds):
            let wait = Duration.seconds(max(seconds, 0))
                .formatted(.units(allowed: [.minutes, .seconds], width: .wide))
            return String(localized: "Save your work and click Quit & Update, or quit \(process) yourself. It will quit automatically in \(wait). Close this notification to defer the update.",
                          table: "Dialogs", bundle: b,
                          comment: "Notification body: the running app, then how long until it is quit. “Quit & Update” is the notification's button; translate it the same way.")
        case .appUpdatedTitle(let app):
            return String(localized: "\(app) Updated", table: "Dialogs", bundle: b,
                          comment: "Notification title")
        case .appWasUpdated(let app, let version, let background):
            switch (version, background) {
            case (let version?, false):
                return String(localized: "\(app) was updated to version \(version).", table: "Dialogs", bundle: b,
                              comment: "Notification body: the app and its new version")
            case (let version?, true):
                return String(localized: "\(app) was updated to version \(version) in the background.", table: "Dialogs", bundle: b,
                              comment: "Notification body: the app and its new version, installed while it wasn't in use")
            case (nil, false):
                return String(localized: "\(app) was updated.", table: "Dialogs", bundle: b,
                              comment: "Notification body")
            case (nil, true):
                return String(localized: "\(app) was updated in the background.", table: "Dialogs", bundle: b,
                              comment: "Notification body: installed while the app wasn't in use")
            }
        case .appsUpdatedTitle(let count):
            return String(localized: "\(count) Apps Updated", table: "Dialogs", bundle: b,
                          comment: "Notification title summarizing several updates")
        case .appList(let names):
            return names.formatted(.list(type: .and))
        }
    }
}

/// Why an item in the apply window was skipped.
enum SkipReason: String, Codable, Equatable {
    case noPlist
    case noType
    case unavailableDrive
    case appRemoved
    case noInstallTarget
    case screenLocked
    case appRunning
    /// The app is open in another logged-in user's session (fast user switching), so
    /// the user at the screen can't see it in their Dock or quit it.
    case inUseByAnotherUser
    /// Not a result: the item waits while the blocking prompt asks the user.
    case waitingForUser

    var text: String {
        let b = Bundle.dialogStrings
        switch self {
        case .noPlist:
            return String(localized: "No plist", table: "Dialogs", bundle: b,
                          comment: "Apply window row: skipped, the app's update details are missing")
        case .noType:
            return String(localized: "No type", table: "Dialogs", bundle: b,
                          comment: "Apply window row: skipped, the update's install type is unknown")
        case .unavailableDrive:
            return String(localized: "Unavailable Drive", table: "Dialogs", bundle: b,
                          comment: "Apply window row: skipped, the app is on a drive that isn't available")
        case .appRemoved:
            return String(localized: "App removed", table: "Dialogs", bundle: b,
                          comment: "Apply window row: skipped, the app was deleted since the scan")
        case .noInstallTarget:
            return String(localized: "No install target", table: "Dialogs", bundle: b,
                          comment: "Apply window row: skipped, nowhere to install the app")
        case .screenLocked:
            return String(localized: "Screen locked", table: "Dialogs", bundle: b,
                          comment: "Apply window row: skipped, the screen locked while waiting to quit the app")
        case .appRunning:
            return String(localized: "App running", table: "Dialogs", bundle: b,
                          comment: "Apply window row: skipped, the app is open and can't be updated")
        case .inUseByAnotherUser:
            return String(localized: "In use by another user", table: "Dialogs", bundle: b,
                          comment: "Apply window row: skipped, the app is open in another user's account on this Mac (fast user switching)")
        case .waitingForUser:
            return String(localized: "Waiting for user…", table: "Dialogs", bundle: b,
                          comment: "Apply window row: paused while a prompt asks the user to quit the app")
        }
    }
}

/// Progress of the download or install step now running.
enum ProgressDetail: Codable, Equatable {
    /// Which kind of step, for telling a new step from progress within one.
    enum Step: String, Codable, Equatable {
        case downloading, installing, copying, openingDiskImage, extracting
    }

    /// `received` / `total` in bytes, when known. curl reports only a fraction.
    case downloading(fraction: Double?, received: Int64?, total: Int64?)
    case installing(fraction: Double?)
    case copying(fraction: Double?)
    case openingDiskImage
    case extracting

    var step: Step {
        switch self {
        case .downloading:      return .downloading
        case .installing:       return .installing
        case .copying:          return .copying
        case .openingDiskImage: return .openingDiskImage
        case .extracting:       return .extracting
        }
    }

    /// 0…1, or nil when the step can't measure itself (a spinner is shown).
    var fraction: Double? {
        let raw: Double?
        switch self {
        case .downloading(let fraction, _, _), .installing(let fraction), .copying(let fraction):
            raw = fraction
        case .openingDiskImage, .extracting:
            raw = nil
        }
        return raw.map { min(max($0, 0), 1) }
    }

    /// "Downloading 45% · 12 MB of 98 MB", "Installing 30%", "Extracting…".
    var text: String {
        let b = Bundle.dialogStrings
        switch self {
        case .downloading(_, let received, let total):
            if let percent = percentText {
                if let received, let total, total > 0 {
                    let receivedText = Self.bytes(received), totalText = Self.bytes(total)
                    return String(localized: "Downloading \(percent) · \(receivedText) of \(totalText)",
                                  table: "Dialogs", bundle: b,
                                  comment: "Download progress: percent, then bytes received of the total size")
                }
                return String(localized: "Downloading \(percent)", table: "Dialogs", bundle: b,
                              comment: "Download progress: percent done")
            }
            if let received, received > 0 {
                let receivedText = Self.bytes(received)
                return String(localized: "Downloading · \(receivedText)", table: "Dialogs", bundle: b,
                              comment: "Download progress when the total size is unknown: bytes received so far")
            }
            return String(localized: "Downloading…", table: "Dialogs", bundle: b,
                          comment: "Download progress before anything has been received")
        case .installing:
            if let percent = percentText {
                return String(localized: "Installing \(percent)", table: "Dialogs", bundle: b,
                              comment: "Install progress: percent done")
            }
            return String(localized: "Installing…", table: "Dialogs", bundle: b,
                          comment: "Install progress that can't be measured")
        case .copying:
            if let percent = percentText {
                return String(localized: "Copying \(percent)", table: "Dialogs", bundle: b,
                              comment: "Progress copying an app into place: percent done")
            }
            return String(localized: "Copying…", table: "Dialogs", bundle: b,
                          comment: "Progress copying an app into place, not measured")
        case .openingDiskImage:
            return String(localized: "Opening disk image…", table: "Dialogs", bundle: b,
                          comment: "Install step: mounting the downloaded disk image")
        case .extracting:
            return String(localized: "Extracting…", table: "Dialogs", bundle: b,
                          comment: "Install step: unpacking the downloaded archive")
        }
    }

    /// "45%", rounded down so 100% means done.
    private var percentText: String? {
        fraction.map { (($0 * 100).rounded(.down) / 100).formatted(.percent.precision(.fractionLength(0))) }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

// MARK: - Bundle

// MARK: - JSON values

extension DialogText {
    /// The value as a JSON object, for files written with JSONSerialization
    /// (`active_phase.json`).
    var jsonObject: Any? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Reads a value written by `jsonObject`; nil when absent or from a newer patcher
    /// this build can't read.
    init?(jsonObject: Any?) {
        guard let jsonObject, JSONSerialization.isValidJSONObject(jsonObject),
              let data = try? JSONSerialization.data(withJSONObject: jsonObject),
              let value = try? JSONDecoder().decode(DialogText.self, from: data)
        else { return nil }
        self = value
    }
}

extension Bundle {
    /// Where the "Dialogs" table lives: PatcherNotifier itself, or PatcherNotifier.app for
    /// the other apps. Command-line tools (patcher, running as root) read the app's English
    /// table directly, so the English they log gets its plurals right; with no
    /// PatcherNotifier installed, they use the keys as written.
    static let dialogStrings: Bundle = {
        let main = Bundle.main
        let notifierURL = AppConstants.patcherNotifierAppURL
        guard main.bundleURL.pathExtension == "app" else {
            let english = notifierURL.appendingPathComponent("Contents/Resources/en.lproj")
            return Bundle(url: english) ?? main
        }
        if main.bundleURL.lastPathComponent == notifierURL.lastPathComponent { return main }
        return Bundle(url: notifierURL) ?? main
    }()
}
