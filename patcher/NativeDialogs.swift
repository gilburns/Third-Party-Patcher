//
//  NativeDialogs.swift
//  patcher
//
//  Windows drawn by PatcherNotifier. patcher describes each window as a DialogSession
//  and rewrites its file on every change; the agent in the user's session renders it.
//
//  Covers the large and compact apply windows and the scan/check/stage window. The
//  prompts are in NativeBlockingPrompt; the deferral prompt is the apply window's choosing phase.
//

import Foundation

// MARK: - Agent availability

enum PatcherNotifierAgent {

    static var binaryURL: URL {
        AppConstants.patcherNotifierAppURL.appendingPathComponent("Contents/MacOS/PatcherNotifier")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: binaryURL.path)
    }

    /// True when the PatcherNotifier LaunchAgent is loaded in this user's GUI session.
    static func isLoaded(uid: uid_t) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["print", "gui/\(uid)/\(AppConstants.patcherNotifierLaunchAgentLabel)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError  = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// The console user's uid when PatcherNotifier can show a window to them, else nil.
    static func windowTargetUID() -> uid_t? {
        guard let uid = consoleUserUID, uid > 0 else {
            Logger.log("ℹ️ Native windows: no console user logged in.")
            return nil
        }
        guard isInstalled else {
            Logger.log("ℹ️ Native windows: PatcherNotifier not found at \(AppConstants.patcherNotifierAppURL.path).")
            return nil
        }
        guard isLoaded(uid: uid) else {
            Logger.log("ℹ️ Native windows: PatcherNotifier LaunchAgent is not loaded for uid \(uid).")
            return nil
        }
        return uid
    }
}

// MARK: - Session writer

/// Owns one DialogSession and writes it on every change.
final class DialogSessionWriter {

    private(set) var session: DialogSession
    private(set) var isClosed = false

    init(session: DialogSession) {
        self.session = session
        DialogSessionStore.write(session)
    }

    /// Applies `change` and writes the file.
    func update(_ change: (inout DialogSession) -> Void) {
        guard !isClosed else { return }
        change(&session)
        session.revision += 1
        session.expires = Date().addingTimeInterval(DialogSessionStore.lifetime)
        DialogSessionStore.write(session)
    }

    /// Removes the session file, which closes the window.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        DialogSessionStore.remove(id: session.id)
    }

    /// A new session with the shared defaults filled in from preferences.
    static func makeSession(kind: DialogSession.Kind, uid: uid_t, prefs: Preferences,
                            position: String, title: DialogText, message: DialogText?,
                            total: Int) -> DialogSession {
        let now = Date()
        let dialogIcon = resolveDialogIcon(prefs: prefs)
        return DialogSession(
            id:          UUID().uuidString,
            kind:        kind,
            consoleUID:  UInt32(uid),
            ownerPID:    ProcessInfo.processInfo.processIdentifier,
            created:     now,
            expires:     now.addingTimeInterval(DialogSessionStore.lifetime),
            revision:    0,
            phase:       .running,
            window: DialogSession.WindowOptions(
                position:      position,
                onTop:         prefs.dialogOnTop,
                movable:       prefs.dialogMoveable,
                blurScreen:    false,
                hideOtherApps: false,
                buttons:       []
            ),
            branding: DialogSession.Branding(
                appTitle:           prefs.appTitle,
                textColorHex:       brandColorHex(prefs.brandColorFont),
                backgroundColorHex: brandColorHex(prefs.brandColorBackground),
                textColorDarkHex:       prefs.brandColorFontDark.map(brandColorHex),
                backgroundColorDarkHex: prefs.brandColorBackgroundDark.map(brandColorHex),
                icon:               dialogIcon
            ),
            icon:        dialogIcon,
            overlayIcon: resolveOverlayIcon(prefs: prefs),
            title:       title,
            message:     message,
            sidePanel:   nil,
            items:       [],
            progress:    DialogSession.Progress(current: 0, total: max(total, 0), indeterminate: false),
            button:      nil,
            secondaryButton: nil,
            countdown:   nil,
            menu:        nil,
            help:        nil,
            autoCloseAt: nil
        )
    }
}

/// The installer package icon, used for items without an icon of their own.
let packageIconPath = "/System/Library/CoreServices/Installer.app/Contents/Resources/package.icns"

// MARK: - Apply window

final class NativeApplyWindow: ApplyPresenter, DeferralPresenter {

    private let uid: uid_t
    private var writer: DialogSessionWriter?
    /// Fixed by `dialog-demo`; otherwise read from ApplyDialogSize at launch.
    private let sizeOverride: ApplyDialogSize?
    private var size: ApplyDialogSize = .large
    /// Items whose result is final, for the large window's progress bar.
    private var finishedCount = 0
    /// The compact window's "Update 2 of 5", kept so progress can be appended to it.
    private var compactStepText = DialogText.verbatim("")
    /// The compact window's own icon and overlay, restored once the run completes.
    private var baseIcon: String?
    private var baseOverlay: String?
    /// Apps the user unchecked while choosing, and for how long they're deferred. They stay
    /// in the large window's list, marked deferred.
    private var deferredLabels: Set<String> = []
    private var deferredMinutes = 0

    /// How long the compact window holds each result before the next item replaces it.
    private static let compactResultHoldSeconds: TimeInterval = 1.5

    var promptUID: uid_t? { uid }

    init(uid: uid_t, size: ApplyDialogSize? = nil) {
        self.uid = uid
        self.sizeOverride = size
    }

    // MARK: ApplyPresenter

    func launchProgressDialog(items: [ApplyItem]) {
        guard !items.isEmpty else {
            writer?.close()
            return
        }
        let prefs = Preferences()
        size = resolvedSize(prefs)
        let count = items.count

        // The deferral prompt's window turns into the progress window in place.
        if let writer, !writer.isClosed, writer.session.phase == .choosing {
            continueFromChoosing(installing: count, prefs: prefs)
            return
        }

        DialogSessionStore.removeAll(kinds: [.applyList, .applyCompact])

        switch size {
        case .large, .notifications:
            var session = DialogSessionWriter.makeSession(
                kind: .applyList, uid: uid, prefs: prefs, position: prefs.dialogScreenPosition,
                title: .verbatim(prefs.appTitle), message: nil, total: count)
            applyLargeWindowOptions(to: &session, prefs: prefs)
            session.sidePanel    = Self.installingPanel(count: count, deferred: [], deferredMinutes: 0)
            session.items            = items.map(Self.row)
            session.progress.caption = .preparing
            session.button           = DialogSession.Button(.updating, enabled: false)
            session.help          = makeHelp(prefs: prefs, started: Date())
            writer = DialogSessionWriter(session: session)

        case .compact:
            var session = DialogSessionWriter.makeSession(
                kind: .applyCompact, uid: uid, prefs: prefs, position: prefs.dialogScreenProgressPosition,
                title: .verbatim(prefs.appTitle), message: .updatesWaiting(count: count), total: count)
            session.progress.caption = .preparing
            baseIcon    = session.icon
            baseOverlay = session.overlayIcon
            writer = DialogSessionWriter(session: session)
        }
        Logger.log("ℹ️ Native apply window opened (\(size == .compact ? "compact" : "large"), \(count) item\(count == 1 ? "" : "s")).")
    }

    func setProgressText(_ text: DialogText) {
        writer?.update { $0.progress.caption = text }
    }

    func setInProgress(item: ApplyItem, current: Int, total: Int) {
        if size == .compact {
            compactStepText = .updateOfTotal(current: current, total: total)
            writer?.update { s in
                showItemIcon(item, in: &s)
                // The bar counts finished updates; this one's progress is added as it arrives.
                s.progress.current  = current - 1
                s.progress.fraction = nil
                s.progress.caption  = compactStepText
                s.message       = .installingApp(app: item.displayName, version: item.newVersion)
            }
            return
        }
        writer?.update { s in
            s.progress.caption = .updateOfTotalInstalling(current: current, total: total, app: item.displayName)
            setRow(item, status: .working, text: .progress(.installing(fraction: nil)), in: &s)
        }
    }

    func setItemProgress(item: ApplyItem, detail: ProgressDetail) {
        let fraction = detail.fraction
        if size == .compact {
            writer?.update { s in
                s.progress.fraction = fraction
                s.progress.caption  = .withDetail(compactStepText, .progress(detail))
            }
            return
        }
        writer?.update { s in
            guard let index = s.items.firstIndex(where: { $0.id == item.label }),
                  s.items[index].status == .working else { return }
            s.items[index].statusDetail = .progress(detail)
            s.items[index].progress     = fraction
            s.progress.fraction         = fraction
        }
    }

    func setSuccess(item: ApplyItem, toVersion: String) {
        finish(item, status: .success, rowText: .updated,
               compactMessage: .updatedApp(app: item.displayName, version: toVersion))
    }

    func setFailed(item: ApplyItem) {
        finish(item, status: .failed, rowText: .failed,
               compactMessage: .failedApp(app: item.displayName, version: item.newVersion))
    }

    func setSkipped(item: ApplyItem, reason: SkipReason) {
        finish(item, status: .skipped, rowText: .skipped(reason),
               compactMessage: .skippedApp(app: item.displayName, reason: reason))
    }

    func complete(applied: Int, skipped: Int, failed: Int) {
        let summary = DialogText.completeSummary(applied: applied, skipped: skipped, failed: failed)

        if size == .compact {
            writer?.update { s in
                s.icon             = baseIcon
                s.overlayIcon      = baseOverlay
                // The summary is in the caption under the bar.
                s.message      = .allUpdatesApplied
                s.progress.current = s.progress.total
                s.progress.caption = summary
                s.phase            = .complete
            }
            // The compact window has no Done button: show the summary briefly, then close.
            Thread.sleep(forTimeInterval: 3.0)
            writer?.close()
            return
        }

        writer?.update { s in
            s.sidePanel    = .paragraphs([.allUpdatesApplied, .updatesJustAttempted])
            s.progress.current = s.progress.total
            s.progress.indeterminate = false
            s.progress.caption = summary
            s.button           = DialogSession.Button(.done, enabled: true)
            s.phase            = .complete
        }
    }

    /// PatcherNotifier closes the window itself when the user clicks Done or the timeout
    /// passes, so patcher never waits here. The session file outlives this process.
    func waitForDialog(timeout: TimeInterval?) {
        guard let timeout, let writer, !writer.isClosed else { return }
        writer.update { $0.autoCloseAt = Date().addingTimeInterval(timeout) }
    }

    func dismiss() {
        writer?.close()
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
            forceQuit(processName)
            return .proceed
        case .defer_:
            Logger.log("ℹ️ BlockingProcessAction=defer — skipping '\(item.label)' this cycle")
            return .skip
        case .notify:
            NativeBlockingPrompt(uid: uid).notify(processName: processName, item: item)
            return .skip
        case .prompt:
            // Show the pause in this window while the prompt waits.
            setProgressText(.waitingForUserApp(item.displayName))
            setSkipped(item: item, reason: .waitingForUser)
            return NativeBlockingPrompt(uid: uid).prompt(processName: processName, item: item,
                                                         countdownSeconds: countdownSeconds,
                                                         deferIfScreenLocks: deferIfScreenLocks)
        }
    }

    // MARK: DeferralPresenter

    /// Opens the apply window in its choosing phase: each app with an "install now"
    /// checkbox (when DeferralPerAppEnabled and not at the hard deadline), the countdown,
    /// the "Defer for" menu, Defer All and Install. Install keeps the window, and
    /// `launchProgressDialog` turns it into the progress window; Defer All closes it.
    ///
    /// patcher owns the countdown, which starts once the agent reports the window is on
    /// screen. If it never appears, the apply proceeds: running apps are still protected by
    /// the blocking-app prompt.
    func showDeferralPrompt(items: [ApplyItem], daysPending: Int, hardDeadlineReached: Bool,
                            hardDeadline: Date?,
                            allowedDeferralMinutes: [Int], prefs: Preferences) -> DeferralPromptResult {
        let menu        = allowedDeferralMinutes
        let defaultMins = DeferralMenu.effectiveDefault(prefs.deferralTimerDefault, menu: menu)
        let seconds     = max(prefs.deferralCountdownSeconds, 1)
        let autoAction  = prefs.deferralAutomaticAction.lowercased()
        let perApp      = prefs.deferralPerAppEnabled && !hardDeadlineReached && items.count > 1
        let count       = items.count
        size = resolvedSize(prefs)

        var sentences: [DialogText] = [.readyToInstall(count: count)]
        if perApp { sentences.append(.uncheckToPutOff) }
        let message: DialogText
        if hardDeadlineReached {
            message = .paragraphs([.sentences(sentences), .installationRequired])
        } else {
            if daysPending > 0 { sentences.append(.pendingForDays(count: count, days: daysPending)) }
            message = .sentences(sentences)
        }

        DialogSessionStore.removeAll(kinds: [.applyList, .applyCompact])
        var session = DialogSessionWriter.makeSession(
            kind: .applyList, uid: uid, prefs: prefs, position: prefs.dialogScreenPosition,
            title: .verbatim(prefs.appTitle), message: message, total: count)
        applyLargeWindowOptions(to: &session, prefs: prefs)
        session.phase = .choosing
        let state = DeferralState.load()
        session.sidePanel = .deferralStatus(daysPending: daysPending,
                                                userDeferrals: state.userDeferralCount,
                                                autoDeferrals: state.automatedDeferralCount,
                                                deadline: hardDeadline)
        if hardDeadline != nil || hardDeadlineReached {
            session.deadline = DialogSession.Deadline(date: hardDeadline, reached: hardDeadlineReached)
        }
        session.items = items.map { item in
            var row = Self.row(item)
            row.status       = item.isBlocked ? .blocked : .ready
            row.statusDetail = item.isBlocked ? .openWillAskToQuit : .ready
            row.selected     = perApp ? true : nil
            return row
        }
        if hardDeadlineReached {
            session.button = DialogSession.Button(.installNow, enabled: true)
        } else {
            session.button = DialogSession.Button(count == 1 ? .installNow : .installAllNow, enabled: true)
            session.secondaryButton = DialogSession.Button(
                menu.isEmpty ? .deferForDuration(minutes: defaultMins) : (count == 1 ? .deferOne : .deferAll),
                enabled: true)
            if !menu.isEmpty {
                session.menu = DialogSession.Menu(
                    title:     .deferForMenu,
                    options:   menu.map { DialogSession.Menu.Option(value: String($0), label: .shortDuration(minutes: $0)) },
                    selected:  String(defaultMins))
            }
        }

        let writer = DialogSessionWriter(session: session)
        self.writer = writer
        let id = session.id
        DialogSessionStore.removeResponses(id: id)
        defer { DialogSessionStore.removeResponses(id: id) }
        Logger.log("ℹ️ Deferral: apply window opened to choose (\(count) item\(count == 1 ? "" : "s"), \(seconds)s\(perApp ? ", per-app" : ""))")

        /// The window closes: Defer All, or closed without an answer.
        func closeWindow() {
            writer.close()
            self.writer = nil
        }
        func menuMinutes(_ value: String?) -> Int {
            // The daemon only accepts a value from the menu; fall back to the default otherwise.
            value.flatMap(Int.init).flatMap { menu.contains($0) ? $0 : nil } ?? defaultMins
        }

        guard waitForDisplay(id: id) else {
            Logger.log("⚠️ Deferral: window was not shown within \(Int(NativeBlockingPrompt.displayTimeout))s — proceeding")
            return hardDeadlineReached ? .deadlineForced : .proceed
        }

        let ends = Date().addingTimeInterval(TimeInterval(seconds))
        writer.update { $0.countdown = DialogSession.Countdown(ends: ends, seconds: seconds) }

        while Date() < ends {
            if shutdownRequested {
                Logger.log("⚠️ Deferral: shutdown requested while prompting — proceeding (the apply loop stops)")
                return hardDeadlineReached ? .deadlineForced : .proceed
            }
            if let value = DialogSessionStore.takeResponseValue(id: id, .primary) {
                if hardDeadlineReached {
                    Logger.log("ℹ️ Deferral: hard deadline — user chose Install")
                    return .deadlineForced
                }
                let choice   = DialogChoice.decode(value)
                let deferred = Set(choice?.deferred ?? []).intersection(session.selectableIDs)
                guard !deferred.isEmpty else {
                    Logger.log("ℹ️ Deferral: user chose to install everything now")
                    return .proceed
                }
                let minutes = menuMinutes(choice?.minutes)
                deferredLabels  = deferred
                deferredMinutes = minutes
                Logger.log("ℹ️ Deferral: user deferred \(deferred.sorted().joined(separator: ", ")) for \(formatDeferralDuration(minutes)); installing the rest")
                return .partial(deferred: deferred.sorted(), minutes: minutes)
            }
            if let value = DialogSessionStore.takeResponseValue(id: id, .secondary) {
                let minutes = menuMinutes(value)
                Logger.log("ℹ️ Deferral: user deferred all for \(formatDeferralDuration(minutes))")
                closeWindow()
                return .deferred(minutes: minutes)
            }
            if DialogSessionStore.takeResponse(id: id, .dismissed) {
                // The agent has closed the window; a progress window is opened afresh.
                closeWindow()
                if hardDeadlineReached {
                    Logger.log("ℹ️ Deferral: hard deadline — window dismissed, proceeding")
                    return .deadlineForced
                }
                // Dismissing is a deferral, not consent.
                Logger.log("ℹ️ Deferral: user dismissed the window — deferring \(formatDeferralDuration(defaultMins))")
                return .deferred(minutes: defaultMins)
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        // The countdown ended: the automatic action applies to every app, whatever is checked.
        if hardDeadlineReached {
            Logger.log("ℹ️ Deferral: hard deadline — countdown ended, proceeding")
            return .deadlineForced
        }
        if autoAction == "continue" {
            Logger.log("ℹ️ Deferral: timer expired — auto-continuing")
            return .proceed
        }
        Logger.log("ℹ️ Deferral: timer expired — auto-deferring \(formatDeferralDuration(defaultMins))")
        closeWindow()
        return .timedOutDeferred(minutes: defaultMins)
    }

    /// Waits for PatcherNotifier to report the window on screen.
    private func waitForDisplay(id: String) -> Bool {
        let deadline = Date().addingTimeInterval(NativeBlockingPrompt.displayTimeout)
        while Date() < deadline, !shutdownRequested {
            if DialogSessionStore.takeResponse(id: id, .displayed) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    /// Turns the choosing window into the progress window: the large window in place, or
    /// shrunk to the compact window.
    private func continueFromChoosing(installing count: Int, prefs: Preferences) {
        let deferred = deferredLabels
        let deferredMinutes = deferredMinutes
        writer?.update { s in
            let deferredNames = s.items.filter { deferred.contains($0.id) }.map(\.title)
            s.phase           = .running
            s.countdown       = nil
            s.menu            = nil
            s.secondaryButton = nil
            s.progress        = DialogSession.Progress(current: 0, total: count, indeterminate: false,
                                                       caption: .preparing)
            switch size {
            case .compact:
                s.kind              = .applyCompact
                s.window.position   = prefs.dialogScreenProgressPosition
                s.window.blurScreen = false
                s.window.buttons    = []
                s.sidePanel         = nil
                s.items             = []
                s.button            = nil
                s.help              = nil
                s.sidePanel     = nil
                s.message       = .updatesWaiting(count: count)
            case .large, .notifications:
                s.message   = nil
                s.sidePanel = Self.installingPanel(count: count, deferred: deferredNames,
                                                       deferredMinutes: deferredMinutes)
                s.items     = s.items.map { row in
                    var row = row
                    row.selected = nil
                    row.progress = nil
                    if deferred.contains(row.id) {
                        row.status       = .deferred
                        row.statusDetail = .deferredFor(minutes: deferredMinutes)
                    } else {
                        row.status       = .pending
                        row.statusDetail = .waiting
                    }
                    return row
                }
                s.button = DialogSession.Button(.updating, enabled: false)
                s.help   = makeHelp(prefs: prefs, started: Date())
            }
        }
        if size == .compact {
            baseIcon    = writer?.session.icon
            baseOverlay = writer?.session.overlayIcon
        }
        Logger.log("ℹ️ Native apply window continued from choosing (\(size == .compact ? "compact" : "large"), \(count) item\(count == 1 ? "" : "s")).")
    }

    /// The large window's side panel while installing.
    private static func installingPanel(count: Int, deferred: [String], deferredMinutes: Int) -> DialogText {
        var paragraphs: [DialogText] = [.updatesWaiting(count: count), .updatesBeingAttempted]
        if !deferred.isEmpty { paragraphs.append(.appsDeferred(names: deferred, minutes: deferredMinutes)) }
        return .paragraphs(paragraphs)
    }

    private func resolvedSize(_ prefs: Preferences) -> ApplyDialogSize {
        let size = sizeOverride ?? ApplyDialogSize(rawValue: prefs.applyDialogSize)
        // .notifications only reaches a window when PatcherNotifier notifications are
        // unavailable — use the default window.
        return size == .notifications ? .large : size
    }

    /// Blur, hidden apps and title-bar buttons: the large window's preferences.
    private func applyLargeWindowOptions(to session: inout DialogSession, prefs: Preferences) {
        session.window.blurScreen    = prefs.dialogBlurscreen
        session.window.hideOtherApps = prefs.dialogHideotherapps
        session.window.buttons       = prefs.dialogShowWindowButtons
            .lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { ["close", "min", "max"].contains($0) }
    }

    // MARK: Helpers

    private func finish(_ item: ApplyItem, status: DialogSession.Item.Status, rowText: DialogText, compactMessage: DialogText) {
        if size == .compact {
            writer?.update { s in
                showItemIcon(item, in: &s)
                s.message = compactMessage
                if isFinalResult(status: status, rowText: rowText) {
                    s.progress.current  = min(s.progress.current + 1, s.progress.total)
                    s.progress.fraction = nil
                    s.progress.caption  = compactStepText
                }
            }
            Thread.sleep(forTimeInterval: Self.compactResultHoldSeconds)
            return
        }
        let isFinal = isFinalResult(status: status, rowText: rowText)
        writer?.update { s in
            let wasFinal = s.items.first(where: { $0.id == item.label }).map(Self.isFinal) ?? false
            setRow(item, status: status, text: rowText, in: &s)
            s.progress.fraction = nil
            if isFinal && !wasFinal {
                finishedCount += 1
                s.progress.current = min(finishedCount, s.progress.total)
            }
        }
    }

    /// Waiting for the user is a pause, not a result.
    private func isFinalResult(status: DialogSession.Item.Status, rowText: DialogText) -> Bool {
        !(status == .skipped && rowText == .skipped(.waitingForUser))
    }

    private static func isFinal(_ row: DialogSession.Item) -> Bool {
        switch row.status {
        case .success, .failed: return true
        case .skipped:          return row.statusDetail != .skipped(.waitingForUser)
        case .pending, .working, .ready, .blocked, .deferred: return false
        }
    }

    /// Sets the row's status.
    private func setRow(_ item: ApplyItem, status: DialogSession.Item.Status, text: DialogText, in s: inout DialogSession) {
        if let index = s.items.firstIndex(where: { $0.id == item.label }) {
            s.items[index].status       = status
            s.items[index].statusDetail = text
            s.items[index].progress     = nil
        } else {
            var row = Self.row(item)
            row.status       = status
            row.statusDetail = text
            s.items.append(row)
        }
    }

    /// Swaps in the item's icon, with the window's own icon as the overlay badge.
    private func showItemIcon(_ item: ApplyItem, in s: inout DialogSession) {
        s.icon        = item.iconPath ?? packageIconPath
        s.overlayIcon = baseIcon
    }

    private static func row(_ item: ApplyItem) -> DialogSession.Item {
        var subtitle: String?
        if let installed = item.installedVersion, !installed.isEmpty,
           let new = item.newVersion, !new.isEmpty {
            subtitle = "\(installed) → \(new)"
        }
        return DialogSession.Item(id: item.label, title: item.displayName, subtitle: subtitle,
                                  icon: item.iconPath ?? packageIconPath,
                                  status: .pending, statusDetail: .waiting)
    }
}

// MARK: - Help contents

/// The support and computer details shown by the large window's help button.
func makeHelp(prefs: Preferences, started: Date) -> DialogSession.Help {
    typealias Row = DialogSession.Help.Row
    var contact: [Row] = []
    let phone   = prefs.supportTeamPhone
    let email   = prefs.supportTeamEmail
    let website = prefs.supportTeamWebsite
    if phone != "hide", !phone.isEmpty { contact.append(Row(label: .phone, value: .verbatim(phone))) }
    if email != "hide", !email.isEmpty {
        contact.append(Row(label: .email, value: .verbatim(email), link: "mailto:\(email)"))
    }
    if website != "hide", !website.isEmpty {
        let url = (website.hasPrefix("https://") || website.hasPrefix("http://")) ? website : "https://\(website)"
        contact.append(Row(label: .website, value: .verbatim(website), link: url))
    }
    return DialogSession.Help(
        supportTeamName: prefs.supportTeamName,
        contact: contact,
        computer: [
            Row(label: .computerName, value: .verbatim(Host.current().localizedName ?? "")),
            Row(label: .serialNumber, value: .verbatim(macSerialNumber)),
            Row(label: .started, value: .date(started)),
        ],
        software: [
            Row(label: .verbatim(AppConstants.patcherFullName), value: .verbatim(AppConstants.patcherVersion)),
            Row(label: .verbatim("Installomator"), value: .verbatim(installomatorVersion)),
            Row(label: .verbatim("macOS"), value: .verbatim(macOSVersion)),
        ]
    )
}

// MARK: - Scan / check / stage progress window

final class NativeProgressWindow: ProgressWindowPresenter {

    private let writer: DialogSessionWriter
    private let baseIcon: String?
    private let baseOverlay: String?
    /// "2 of 5" for the item started by `beginItem`, kept so progress can be appended to it.
    private var itemStepText: DialogText?

    init(uid: uid_t, title: DialogText, message: DialogText, total: Int) {
        let prefs = Preferences()
        DialogSessionStore.removeAll(kinds: [.progress])
        let session = DialogSessionWriter.makeSession(
            kind: .progress, uid: uid, prefs: prefs, position: prefs.dialogScreenProgressPosition,
            title: title, message: message, total: total)
        baseIcon    = session.icon
        baseOverlay = session.overlayIcon
        writer = DialogSessionWriter(session: session)
        Logger.log("ℹ️ Native progress window opened: \(title.text)")
    }

    func update(message: DialogText) {
        writer.update { $0.message = message }
    }

    func updateProgress(_ text: DialogText) {
        writer.update { $0.progress.caption = text }
    }

    func setProgress(_ current: Int, of total: Int, label: DialogText, icon: String?) {
        writer.update { s in
            if let icon {
                s.icon        = icon
                s.overlayIcon = baseIcon
            }
            s.message = label
            s.progress.current = current
            s.progress.total   = total
            s.progress.indeterminate = false
            s.progress.caption = .countOfTotal(current: current, total: total)
        }
    }

    func beginItem(current: Int, of total: Int, label: DialogText, icon: String?) {
        writer.update { s in
            if let icon {
                s.icon        = icon
                s.overlayIcon = baseIcon
            }
            s.message = label
            s.progress.total   = total
            s.progress.indeterminate = true
            s.progress.fraction = nil
            s.progress.caption = .countOfTotal(current: current, total: total)
        }
        itemStepText = .countOfTotal(current: current, total: total)
    }

    func setItemProgress(_ detail: ProgressDetail) {
        let fraction = detail.fraction
        writer.update { s in
            s.progress.indeterminate = fraction == nil
            s.progress.fraction      = fraction
            s.progress.caption       = itemStepText.map { .withDetail($0, .progress(detail)) } ?? .progress(detail)
        }
    }

    func completeItem(current: Int, of total: Int) {
        itemStepText = nil
        writer.update { s in
            s.progress.current = current
            s.progress.total   = total
            s.progress.indeterminate = false
            s.progress.fraction = nil
            s.progress.caption = .countOfTotal(current: current, total: total)
        }
    }

    func resetIcons() {
        writer.update { s in
            s.icon        = baseIcon
            s.overlayIcon = baseOverlay
        }
    }

    func close() {
        writer.update { s in
            s.progress.current = s.progress.total
            s.progress.indeterminate = false
            s.message = .processCompleted
            s.phase   = .complete
        }
        Thread.sleep(forTimeInterval: 3.0)
        writer.close()
    }
}
