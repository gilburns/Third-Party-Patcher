//
//  NativeDialogs.swift
//  patcher
//
//  Windows drawn by PatcherNotifier. patcher describes each window as a DialogSession
//  and rewrites its file on every change; the agent in the user's session renders it.
//
//  Covers the large and compact apply windows and the scan/check/stage window. The
//  prompts are in NativeBlockingPrompt and NativeDeferralPrompt.
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
                            position: String, title: String, message: String,
                            total: Int) -> DialogSession {
        let now = Date()
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
                backgroundColorHex: brandColorHex(prefs.brandColorBackground)
            ),
            icon:        resolveDialogIcon(prefs: prefs),
            overlayIcon: resolveOverlayIcon(prefs: prefs),
            title:       title,
            message:     message,
            sidePanel:   nil,
            items:       [],
            progress:    DialogSession.Progress(current: 0, total: max(total, 0), indeterminate: false, text: ""),
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
    /// The compact window's own icon and overlay, restored once the run completes.
    private var baseIcon: String?
    private var baseOverlay: String?

    /// How long the compact window holds each result before the next item replaces it.
    private static let compactResultHoldSeconds: TimeInterval = 1.5

    init(uid: uid_t, size: ApplyDialogSize? = nil) {
        self.uid = uid
        self.sizeOverride = size
    }

    // MARK: ApplyPresenter

    func launchProgressDialog(items: [ApplyItem]) {
        guard !items.isEmpty else { return }
        let prefs = Preferences()
        size = sizeOverride ?? ApplyDialogSize(rawValue: prefs.applyDialogSize)
        // .notifications only reaches a window when PatcherNotifier notifications are
        // unavailable — use the default window.
        if size == .notifications { size = .large }

        DialogSessionStore.removeAll(kinds: [.applyList, .applyCompact])
        let count = items.count
        let word  = count == 1 ? "update" : "updates"

        switch size {
        case .large, .notifications:
            var session = DialogSessionWriter.makeSession(
                kind: .applyList, uid: uid, prefs: prefs, position: prefs.dialogScreenPosition,
                title: prefs.appTitle, message: "", total: count)
            session.window.blurScreen    = prefs.dialogBlurscreen
            session.window.hideOtherApps = prefs.dialogHideotherapps
            session.window.buttons       = prefs.dialogShowWindowButtons
                .lowercased()
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { ["close", "min", "max"].contains($0) }
            session.sidePanel     = "There are **\(count) \(word)** waiting.\n\nThese updates are being attempted."
            session.items         = items.map(Self.row)
            session.progress.text = "Preparing…"
            session.button        = DialogSession.Button(title: "Updating…", enabled: false)
            session.help          = makeHelp(prefs: prefs, started: Date())
            writer = DialogSessionWriter(session: session)

        case .compact:
            var session = DialogSessionWriter.makeSession(
                kind: .applyCompact, uid: uid, prefs: prefs, position: prefs.dialogScreenProgressPosition,
                title: prefs.appTitle, message: "There are **\(count) \(word)** waiting.\n\nPreparing…", total: count)
            session.progress.text = "Preparing…"
            baseIcon    = session.icon
            baseOverlay = session.overlayIcon
            writer = DialogSessionWriter(session: session)
        }
        Logger.log("ℹ️ Native apply window opened (\(size == .compact ? "compact" : "large"), \(count) item\(count == 1 ? "" : "s")).")
    }

    func setProgressText(_ text: String) {
        writer?.update { $0.progress.text = text }
    }

    func setInProgress(item: ApplyItem, current: Int, total: Int) {
        if size == .compact {
            writer?.update { s in
                showItemIcon(item, in: &s)
                s.progress.current = current
                s.progress.text    = "Update \(current) of \(total)"
                s.message          = "Installing: \(item.displayName)\(versionSuffix(item.newVersion))…"
            }
            return
        }
        writer?.update { s in
            s.progress.text = "Update \(current) of \(total) - Installing: \(item.displayName)…"
            setRow(item, status: .working, text: "Installing…", in: &s)
        }
    }

    func setSuccess(item: ApplyItem, toVersion: String) {
        finish(item, status: .success, rowText: "Updated",
               compactMessage: "✅ Updated: \(item.displayName)\(versionSuffix(toVersion))")
    }

    func setFailed(item: ApplyItem) {
        finish(item, status: .failed, rowText: "Failed",
               compactMessage: "❌ Failed: \(item.displayName)\(versionSuffix(item.newVersion))")
    }

    func setSkipped(item: ApplyItem, reason: String) {
        finish(item, status: .skipped, rowText: reason,
               compactMessage: "⚠️ \(item.displayName) — \(reason)")
    }

    func complete(applied: Int, skipped: Int, failed: Int) {
        let summary: String
        if failed > 0 {
            summary = "\(applied) updated · \(skipped) skipped · \(failed) failed"
        } else if skipped > 0 {
            summary = "\(applied) updated · \(skipped) skipped"
        } else {
            summary = "\(applied) update\(applied == 1 ? "" : "s") applied successfully"
        }

        if size == .compact {
            writer?.update { s in
                s.icon             = baseIcon
                s.overlayIcon      = baseOverlay
                s.message          = "**All possible updates have been applied**.\n\n\(summary)"
                s.progress.current = s.progress.total
                s.progress.text    = "Complete — \(summary)"
                s.phase            = .complete
            }
            // The compact window has no Done button: show the summary briefly, then close.
            Thread.sleep(forTimeInterval: 3.0)
            writer?.close()
            return
        }

        writer?.update { s in
            s.sidePanel        = "**All possible updates have been applied**.\n\nThese updates were just attempted."
            s.progress.current = s.progress.total
            s.progress.indeterminate = false
            s.progress.text    = "Complete — \(summary)"
            s.button           = DialogSession.Button(title: "Done", enabled: true)
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
            setProgressText("Waiting for user — \(item.displayName)")
            setSkipped(item: item, reason: "Waiting for user…")
            return NativeBlockingPrompt(uid: uid).prompt(processName: processName, item: item,
                                                         countdownSeconds: countdownSeconds,
                                                         deferIfScreenLocks: deferIfScreenLocks)
        }
    }

    // MARK: DeferralPresenter

    func showDeferralPrompt(items: [ApplyItem], daysPending: Int, hardDeadlineReached: Bool,
                            allowedDeferralMinutes: [Int], prefs: Preferences) -> DeferralPromptResult {
        NativeDeferralPrompt(uid: uid).show(items: items, daysPending: daysPending,
                                            hardDeadlineReached: hardDeadlineReached,
                                            allowedDeferralMinutes: allowedDeferralMinutes, prefs: prefs)
    }

    // MARK: Helpers

    private func finish(_ item: ApplyItem, status: DialogSession.Item.Status, rowText: String, compactMessage: String) {
        if size == .compact {
            writer?.update { s in
                showItemIcon(item, in: &s)
                s.message = compactMessage
            }
            Thread.sleep(forTimeInterval: Self.compactResultHoldSeconds)
            return
        }
        // "Waiting for user…" is a pause, not a result.
        let isFinal = !(status == .skipped && rowText == "Waiting for user…")
        writer?.update { s in
            let wasFinal = s.items.first(where: { $0.id == item.label }).map(Self.isFinal) ?? false
            setRow(item, status: status, text: rowText, in: &s)
            if isFinal && !wasFinal {
                finishedCount += 1
                s.progress.current = min(finishedCount, s.progress.total)
            }
        }
    }

    private static func isFinal(_ row: DialogSession.Item) -> Bool {
        switch row.status {
        case .success, .failed: return true
        case .skipped:          return row.statusText != "Waiting for user…"
        case .pending, .working, .ready, .blocked: return false
        }
    }

    private func setRow(_ item: ApplyItem, status: DialogSession.Item.Status, text: String, in s: inout DialogSession) {
        if let index = s.items.firstIndex(where: { $0.id == item.label }) {
            s.items[index].status     = status
            s.items[index].statusText = text
        } else {
            var row = Self.row(item)
            row.status     = status
            row.statusText = text
            s.items.append(row)
        }
    }

    /// Swaps in the item's icon, with the window's own icon as the overlay badge.
    private func showItemIcon(_ item: ApplyItem, in s: inout DialogSession) {
        s.icon        = item.iconPath ?? packageIconPath
        s.overlayIcon = baseIcon
    }

    private func versionSuffix(_ version: String?) -> String {
        guard let version, !version.isEmpty else { return "" }
        return " → \(version)"
    }

    private static func row(_ item: ApplyItem) -> DialogSession.Item {
        var subtitle: String?
        if let installed = item.installedVersion, !installed.isEmpty,
           let new = item.newVersion, !new.isEmpty {
            subtitle = "\(installed) → \(new)"
        }
        return DialogSession.Item(id: item.label, title: item.displayName, subtitle: subtitle,
                                  icon: item.iconPath ?? packageIconPath,
                                  status: .pending, statusText: "Waiting")
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
    if phone != "hide", !phone.isEmpty { contact.append(Row(label: "Phone", value: phone)) }
    if email != "hide", !email.isEmpty { contact.append(Row(label: "Email", value: email, link: "mailto:\(email)")) }
    if website != "hide", !website.isEmpty {
        let url = (website.hasPrefix("https://") || website.hasPrefix("http://")) ? website : "https://\(website)"
        contact.append(Row(label: "Website", value: website, link: url))
    }
    let started = DateFormatter.localizedString(from: started, dateStyle: .medium, timeStyle: .short)
    return DialogSession.Help(
        supportTeamName: prefs.supportTeamName,
        contact: contact,
        computer: [
            Row(label: "Computer Name", value: Host.current().localizedName ?? ""),
            Row(label: "Serial Number", value: macSerialNumber),
            Row(label: "Started", value: started),
        ],
        software: [
            Row(label: AppConstants.patcherFullName, value: AppConstants.patcherVersion),
            Row(label: "Installomator", value: installomatorVersion),
            Row(label: "macOS", value: macOSVersion),
        ]
    )
}

// MARK: - Scan / check / stage progress window

final class NativeProgressWindow: ProgressWindowPresenter {

    private let writer: DialogSessionWriter
    private let baseIcon: String?
    private let baseOverlay: String?

    init(uid: uid_t, title: String, message: String, total: Int) {
        let prefs = Preferences()
        DialogSessionStore.removeAll(kinds: [.progress])
        let session = DialogSessionWriter.makeSession(
            kind: .progress, uid: uid, prefs: prefs, position: prefs.dialogScreenProgressPosition,
            title: title, message: message, total: total)
        baseIcon    = session.icon
        baseOverlay = session.overlayIcon
        writer = DialogSessionWriter(session: session)
        Logger.log("ℹ️ Native progress window opened: \(title)")
    }

    func update(message: String) {
        writer.update { $0.message = message }
    }

    func updateProgress(_ text: String) {
        writer.update { $0.progress.text = text }
    }

    func setProgress(_ current: Int, of total: Int, label: String, icon: String?) {
        writer.update { s in
            if let icon {
                s.icon        = icon
                s.overlayIcon = baseIcon
            }
            s.message = label
            s.progress.current = current
            s.progress.total   = total
            s.progress.indeterminate = false
            s.progress.text    = "\(current) of \(total)"
        }
    }

    func beginItem(current: Int, of total: Int, label: String, icon: String?) {
        writer.update { s in
            if let icon {
                s.icon        = icon
                s.overlayIcon = baseIcon
            }
            s.message = label
            s.progress.total   = total
            s.progress.indeterminate = true
            s.progress.text    = "\(current) of \(total)"
        }
    }

    func completeItem(current: Int, of total: Int) {
        writer.update { s in
            s.progress.current = current
            s.progress.total   = total
            s.progress.indeterminate = false
            s.progress.text    = "\(current) of \(total)"
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
            s.message = "Process completed"
            s.phase   = .complete
        }
        Thread.sleep(forTimeInterval: 3.0)
        writer.close()
    }
}
