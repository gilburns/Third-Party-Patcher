//
//  SwiftDialogController.swift
//  patcher
//
//  Created by Gil Burns on 4/12/26.
//
//  Manages user-facing progress UI via swiftDialog during the apply phase.
//  patcher runs as root; swiftDialog runs as the console user.  This controller
//  bridges the two via a command file that swiftDialog watches for updates, and
//  by launching blocking-process prompts as separate swiftDialog invocations
//  (whose exit code signals the user's choice).
//
//  Blocking-process actions (set via BlockingProcessAction preference):
//    ignore — skip the blocking-process check; install immediately
//    kill   — force-quit the blocking process silently; install
//    notify — show a brief auto-dismissing swiftDialog banner; skip the label
//    prompt — show a timed swiftDialog asking the user to quit; on timer
//             expiry or "Quit App" click, force-quit and install; "Skip" defers
//    defer  — skip the label silently this cycle (no UI)
//

import AppKit
import Foundation
import SystemConfiguration

// MARK: - Types

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
    case proceedRelaunch // user explicitly clicked "Quit <App>"; relaunch after install
    case skip            // user or policy chose to skip this label
}

enum DeferralPromptResult {
    case proceed                         // user clicked Continue
    case deferred(minutes: Int)          // user explicitly clicked Defer
    case timedOutDeferred(minutes: Int)  // countdown timer expired; auto-deferred
    case deadlineForced                  // hard deadline reached; proceeded without user choice
}


// MARK: - SwiftDialogController

struct SwiftDialogController {

    private let commandFileURL: URL
    private let userUID: uid_t
    private var dialogProcess: Process?

    // MARK: Factory

    /// Returns a controller ready to use, or nil when:
    ///   • swiftDialog is not installed
    ///   • no user is logged in at the console
    ///   • the SwiftDialogEnabled preference is false
    static func makeIfAvailable() -> SwiftDialogController? {
        let prefs = Preferences()
        guard prefs.swiftDialogEnabled else { return nil }
        guard FileManager.default.fileExists(atPath: AppConstants.swiftDialogBinaryURL.path) else {
            Logger.log("ℹ️ swiftDialog not found at \(AppConstants.swiftDialogBinaryURL.path) — applying silently.")
            return nil
        }
        guard let uid = consoleUserUID, uid > 0 else {
            Logger.log("ℹ️ No console user logged in — applying silently.")
            return nil
        }
        // Clear any stale command file from a previous run
        try? FileManager.default.removeItem(at: AppConstants.swiftDialogCommandFileURL)
        return SwiftDialogController(commandFileURL: AppConstants.swiftDialogCommandFileURL, userUID: uid)
    }


    // MARK: Patcher Progress main dialog

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

    /// Launches swiftDialog showing a progress list of all items about to be applied.
    /// This is fire-and-continue — the patcher does not wait for the dialog to exit.
    mutating func launchProgressDialog(items: [ApplyItem]) {
        guard !items.isEmpty else { return }

        let prefs        = Preferences()
        let dialogIcon   = resolveDialogIcon(prefs: prefs)
        let overlayIcon  = resolveOverlayIcon(prefs: prefs)
        let startISO     = ISO8601DateFormatter().string(from: Date())
        let helpMessage  = buildHelpMessage(prefs: prefs, startISO: startISO)
//        let infoboxMessage = buildInfoboxMessage()
        
        // Build the listitem array as structured JSON so swiftDialog parses
        // title, icon, and status correctly from the start.
        let listItems: [[String: String]] = items.map { item in
            var listItem: [String: String] = [
                "title":      item.displayName,
                "icon":       item.iconPath ?? "/System/Library/CoreServices/Installer.app/Contents/Resources/package.icns",
                "status":     "pending",
                "statustext": "Waiting",
            ]
            if let installedVersion = item.installedVersion, !installedVersion.isEmpty,
               let newVersion = item.newVersion, !newVersion.isEmpty {
                listItem["subtitle"] = "\(installedVersion) → \(newVersion)"
            }
            return listItem
        }
        
        let listItemsCount = listItems.count

        var jsonDict: [String: Any] = [
            "presentation":    true,
            "width":           770,
            "height":          min(450, max(520, 220 + items.count * 60)),
            "title":           prefs.appTitle,
            "titlefont":       "size=18",
            "icon":            dialogIcon,
            "iconsize":        128,
//            "message":         "There are **\(listItemsCount) updates** waiting.\n\nThe following updates are being applied:",
//            "messagefont":     "size=16",
            "infobox":         ":\(brandColorHex(prefs.brandColorFont))[\(prefs.appTitle)\n\nThere are **\(listItemsCount) updates** waiting.\n\nThese updates are being attempted 👉]",
            "background":      "colour=\(prefs.brandColorBackground)",
            "helpmessage":     helpMessage,
//            "infobox":         infoboxMessage,
            "progress":        items.count,
            "progresstext":    "Preparing…",
            "commandfile":     commandFileURL.path,
            "button1text":     "Updating…",
            "button1disabled": true,
            "listitem":        listItems,
            "moveable":        true,
            "ontop":           prefs.dialogOnTop,
        ]
        if let overlayIcon { jsonDict["overlayicon"] = overlayIcon }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonDict),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            Logger.log("❌ SwiftDialogController: failed to serialise dialog JSON")
            return
        }

        dialogProcess = launchAsUser(["--jsonstring", jsonString])
        Logger.log("ℹ️ swiftDialog launched (pid \(dialogProcess?.processIdentifier ?? -1))")

        // Allow swiftDialog to initialise before the first command-file update.
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// Marks a list item as in-progress (spinner) and updates the progress text.
    func setInProgress(item: ApplyItem, current: Int, total: Int) {
        sendCommand("progresstext: Update \(current) of \(total) - Installing: \(item.displayName)…")
        sendCommand("listitem: title: \(item.displayName), status: wait, statustext: Installing…")
    }

    /// Marks a list item as successfully applied.
    func setSuccess(item: ApplyItem, toVersion: String) {
        sendCommand("listitem: title: \(item.displayName), status: success, statustext: Updated")
    }

    /// Marks a list item as failed.
    func setFailed(item: ApplyItem) {
        sendCommand("listitem: title: \(item.displayName), status: fail, statustext: Failed")
    }

    /// Marks a list item as skipped.
    func setSkipped(item: ApplyItem, reason: String = "Skipped") {
        sendCommand("listitem: title: \(item.displayName), status: error, statustext: \(reason)")
    }

    /// Updates only the progress bar text without touching list items.
    func setProgressText(_ text: String) {
        sendCommand("progresstext: \(text)")
    }

    /// Updates the dialog to show a completion summary and re-enables the Done button.
    /// Call `dismiss()` after a suitable delay (or when the patcher exits) to close it.
    func complete(applied: Int, skipped: Int, failed: Int) {
        let prefs        = Preferences()

        let summary: String
        if failed > 0 {
            summary = "\(applied) updated · \(skipped) skipped · \(failed) failed"
        } else if skipped > 0 {
            summary = "\(applied) updated · \(skipped) skipped"
        } else {
            summary = "\(applied) update\(applied == 1 ? "" : "s") applied successfully"
        }
        sendCommand("infobox: :\(brandColorHex(prefs.brandColorFont))[\(prefs.appTitle)]")
        sendCommand("infobox: + \n")
        sendCommand("infobox: + \n")
        sendCommand("infobox: + :\(brandColorHex(prefs.brandColorFont))[**All possible updates have been applied**.]")
        sendCommand("infobox: + \n")
        sendCommand("infobox: + \n")
        sendCommand("infobox: + :\(brandColorHex(prefs.brandColorFont))[These updates were just attempted 👉]")
        sendCommand("progress: complete")
        sendCommand("progresstext: Complete — \(summary)")
        sendCommand("button1text: Done")
        sendCommand("button1: enable")
        sendCommand("activate:")
        sendCommand("activate:")
    }

    /// Sends a quit command to close the dialog immediately.
    func dismiss() {
        
        sendCommand("quit:")
    }

    // MARK: - User-initiated progress window (scan / check)

    /// Launches a non-interactive "please wait" progress window for user-initiated
    /// scan/check phases. Returns a `UserProgressDialog` for updating and closing it.
    static func launchProgressWindow(title: String, message: String, total: Int = 0) -> UserProgressDialog? {
        guard let uid = consoleUserUID, uid > 0 else { return nil }

        let cmdURL = AppConstants.swiftDialogProgressCommandFileURL
        try? FileManager.default.removeItem(at: cmdURL)

        let prefs      = Preferences()
        let dialogIcon = resolveDialogIcon(prefs: prefs)

        var jsonDict: [String: Any] = [
            "title":           title,
            "titlefont":       "shadow=1,size=18,alignment=left",
            "icon":            dialogIcon,
            "message":         message,
            "messagefont":     "size=14",
            "progress":        total > 0 ? total : 0,
            "progresstext":    "",
            "commandfile":     cmdURL.path,
            "moveable":        true,
            "mini":            true,
            "ontop":           prefs.dialogOnTop,
            "position":        prefs.dialogScreenProgressPosition,
        ]
        let overlayIcon = resolveOverlayIcon(prefs: prefs)
        if let overlayIcon { jsonDict["overlayicon"] = overlayIcon }

        guard let jsonData   = try? JSONSerialization.data(withJSONObject: jsonDict),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return nil }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments     = ["asuser", "\(uid)", AppConstants.swiftDialogBinaryURL.path,
                           "--jsonstring", jsonString]
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }

        Thread.sleep(forTimeInterval: 3.0)
        return UserProgressDialog(process: p, commandFileURL: cmdURL,
                                  overlayIconPath: dialogIcon, initialOverlayPath: overlayIcon)
    }

    /// Waits for the dialog process to exit, however it exits.
    /// If the user clicks Done the process exits immediately.
    /// Pass a timeout to auto-dismiss via `quit:` after that many seconds.
    /// Pass `nil` to detach: patcher returns immediately and swiftDialog keeps
    /// running in the user's login session until the user clicks Done.
    func waitForDialog(timeout: TimeInterval?) {
        guard let timeout else {
            // Detach — swiftDialog was launched under the user's launchd session
            // via `launchctl asuser` and will outlive this process.
            return
        }

        let process = dialogProcess  // Process is a class — shared reference
        let cmdURL  = commandFileURL // URL is a struct — copied by value

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard process?.isRunning == true else { return }
            guard let data = "quit:\n".data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: cmdURL.path),
               let handle = try? FileHandle(forWritingTo: cmdURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: cmdURL, options: .atomic)
            }
        }

        process?.waitUntilExit()
    }


    // MARK: Deferral prompt

    /// Shows a blocking pre-install prompt that lets the user Continue or Defer.
    /// Returns immediately with `.proceed` if the hard deadline is reached.
    /// Uses `--outputfile` to capture the dropdown selection without stdout issues.
    func showDeferralPrompt(
        items:                  [SwiftDialogController.ApplyItem],
        daysPending:            Int,
        hardDeadlineReached:    Bool,
        allowedDeferralMinutes: [Int],
        prefs:                  Preferences
    ) -> DeferralPromptResult {

        let itemCount    = items.count
        let deferMenu    = allowedDeferralMinutes
        let defaultMins  = prefs.deferralTimerDefault
        let countdown    = prefs.deferralCountdownSeconds
        let autoAction   = prefs.deferralAutomaticAction.lowercased()

        let deferralState  = DeferralState.load()
        let infoboxMessage = buildDeferralInfoboxMessage(daysPending: daysPending, deferralState: deferralState)

        let itemWord = itemCount == 1 ? "update" : "updates"
        var message  = "You have **\(itemCount) software \(itemWord)** that \(itemCount == 1 ? "is" : "are") ready to be installed."
        if hardDeadlineReached {
            message += "\n\nInstallation is required — the maximum deferral deadline has been reached."
        } else if daysPending > 0 {
            message += "\n\nThese \(itemWord) have been pending for **\(daysPending) day\(daysPending == 1 ? "" : "s")**."
        }

        // Build the listitem array so each pending update shows its icon, name, and
        // version transition — mirroring the progress dialog's listitem presentation.
        // Unlike the old text-based message list, this is not truncated to the first
        // several items; swiftDialog scrolls the list when it overflows the window.
        let sortedItems = items.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let listItems: [[String: String]] = sortedItems.map { item in
            var listItem: [String: String] = [
                "title":      item.displayName,
                "icon":       item.iconPath ?? "/System/Library/CoreServices/Installer.app/Contents/Resources/package.icns",
                "status":     item.isBlocked ? "error" : "success",
                "statustext": item.isBlocked ? "Needs to be closed" : "Ready",
            ]
            if let installedVersion = item.installedVersion, !installedVersion.isEmpty,
               let newVersion = item.newVersion, !newVersion.isEmpty {
                listItem["subtitle"] = "\(installedVersion) → \(newVersion)"
            }
            return listItem
        }

        var jsonDict: [String: Any] = [
            "bannertitle":     prefs.appTitle,
            "titlefont":       "shadow=1,size=22,alignment=left,colour=\(prefs.brandColorFont)",
            "bannerimage":     "colour=\(prefs.brandColorBackground)",
            "bannerheight":    70,
            "icon":            resolveDialogIcon(prefs: prefs),
            "message":         message,
            "messagefont":     "size=14",
            "button2text":     "Continue",
            "infobox":         infoboxMessage,
            "listitem":        listItems,
            "moveable":        true,
            "ontop":           prefs.dialogOnTop,
            "position":        prefs.dialogScreenPosition,
            "height":          min(720, max(440, 300 + itemCount * 55)),
            "width":           650,
            "timer":           countdown,
        ]
        if let overlay = resolveOverlayIcon(prefs: prefs) { jsonDict["overlayicon"] = overlay }

        if !hardDeadlineReached {
            jsonDict["button1"]     = true
            jsonDict["button1text"] = deferMenu.isEmpty
                ? "Defer (\(formatDeferralDuration(defaultMins)))"
                : "Defer"
            if !deferMenu.isEmpty {
                // A single selectitems object: one labelled dropdown with all duration choices.
                // swiftDialog interprets each array element as a separate control, so the
                // entire list of options must live inside one object's "values" array.
                jsonDict["selectitems"] = [
                    [
                        "title":   "Defer for",
                        "values":  deferMenu.map { formatDeferralDuration($0) },
                        "default": formatDeferralDuration(defaultMins),
                    ] as [String: Any]
                ]
            }
        }

        guard let jsonData   = try? JSONSerialization.data(withJSONObject: jsonDict),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            Logger.log("❌ DeferralPrompt: JSON serialise failed — proceeding")
            return .proceed
        }

        // Capture stdout via Pipe — swiftDialog writes its selection output to stdout.
        // launchctl asuser passes file descriptors through to the child process, so
        // setting a Pipe on the launchctl Process captures swiftDialog's stdout.
        let stdoutPipe = Pipe()
        let p = launchAsUser(["--jsonstring", jsonString], capturingStdoutWith: stdoutPipe)
        p.waitUntilExit()

        let rawOutput = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        Logger.log("🔍 Deferral stdout: \(rawOutput.trimmingCharacters(in: .whitespacesAndNewlines))")

        if hardDeadlineReached {
            Logger.log("ℹ️ Deferral: hard deadline — proceeding regardless of user choice")
            return .deadlineForced
        }

        switch p.terminationStatus {
        case 0:
            // Defer button clicked
            let minutes = deferMenu.isEmpty
                ? defaultMins
                : parseDeferralSelection(from: rawOutput, menu: deferMenu, fallback: defaultMins)
            Logger.log("ℹ️ Deferral: user deferred \(formatDeferralDuration(minutes)) (exit \(p.terminationStatus))")
            return .deferred(minutes: minutes)
        case 4:
            if autoAction == "continue" {
                Logger.log("ℹ️ Deferral: timer expired — auto-continuing")
                return .proceed
            }
            Logger.log("ℹ️ Deferral: timer expired — auto-deferring \(formatDeferralDuration(defaultMins))")
            return .timedOutDeferred(minutes: defaultMins)
        default:
            Logger.log("ℹ️ Deferral: user chose Continue")
            return .proceed
        }
    }

    /// Parses swiftDialog's stdout and maps the selected dropdown value back to minutes.
    /// swiftDialog writes one `"key" : value` pair per line to stdout.
    /// We look for the line whose key matches the dropdown title "Defer for".
    private func parseDeferralSelection(from output: String, menu: [Int], fallback: Int) -> Int {
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Match lines like:  "Defer for" : "1 hour"
            guard trimmed.hasPrefix("\"Defer for\"") else { continue }
            let parts = trimmed.components(separatedBy: " : ")
            guard parts.count >= 2 else { continue }
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            for mins in menu where formatDeferralDuration(mins) == value { return mins }
        }
        return fallback
    }


    // MARK: Blocking process handling

    /// Handles a blocking process according to the configured action.
    /// Returns `.proceed` if installation should continue, `.skip` to skip the label.
    func handleBlockingProcess(
        processName:      String,
        item:             ApplyItem,
        action:           BlockingProcessAction,
        countdownSeconds: Int
    ) -> BlockingActionResponse {

        switch action {
        case .ignore:
            Logger.log("ℹ️ BlockingProcessAction=ignore — proceeding despite '\(processName)' running")
            return .proceed

        case .kill:
            Logger.log("ℹ️ BlockingProcessAction=kill — force-quitting '\(processName)'")
            killProcess(named: processName)
            return .proceed

        case .defer_:
            Logger.log("ℹ️ BlockingProcessAction=defer — skipping '\(item.label)' this cycle")
            return .skip

        case .notify:
            return handleNotify(processName: processName, item: item)

        case .prompt:
            return handlePrompt(processName: processName, item: item, countdownSeconds: countdownSeconds)
        }
    }

    // MARK: - Notify or Prompt

    // handleBlockingProcess = notify
    private func handleNotify(processName: String, item: ApplyItem) -> BlockingActionResponse {
        Logger.log("ℹ️ BlockingProcessAction=notify — showing notification for '\(processName)'")
        let prefs = Preferences()
        var args: [String] = [
            "--bannertitle",     "Update Pending: \(item.displayName)",
            "--titlefont", "shadow=1,size=18,alignment=left,colour=\(prefs.brandColorFont)",
            "--bannerimage", "colour=\(prefs.brandColorBackground)",
            "--bannerheight", "50",
            "--icon",      "caution",
            "--iconsize", "80",
            "--timer",       "30",
            "--message",   "\(item.displayName) needs to be quit to apply an update. Please close it when convenient.",
            "--messagealignment", "left",
            "--messagefont", "size=16",
            "--moveable",
            "--height",    "200",
            "--width",    "600",
        ]
        if prefs.dialogOnTop { args.append("--ontop") }
        // Use the blocking item's app icon as the overlay so the user sees which
        // app is blocking. Fall back to the pkg icon if no app icon is available.
        let overlayIcon = item.iconPath ?? "/System/Library/CoreServices/Installer.app/Contents/Resources/package.icns"
        args += ["--overlayicon", overlayIcon]

        let prompt = launchAsUser(args)
        prompt.waitUntilExit()
        recordBlockingProcessEvent(label: item.label,
                                   type: LabelHistoryEvent.EventType.blockingProcessNotified,
                                   processName: processName, date: Date())
        return .skip
    }

    // handleBlockingProcess = prompt
    private func handlePrompt(processName: String, item: ApplyItem, countdownSeconds: Int) -> BlockingActionResponse {
        Logger.log("ℹ️ BlockingProcessAction=prompt — showing blocking-process dialog for '\(processName)'")

        // Pause the progress dialog while waiting for user input
        setProgressText("Waiting for user — \(item.displayName)")
        setSkipped(item: item, reason: "Waiting for user…")
        let prefs = Preferences()
        var args: [String] = [
            "--bannertitle",       "\(item.displayName) Update Paused",
            "--titlefont", "shadow=1,size=18,alignment=left,colour=\(prefs.brandColorFont)",
            "--bannerimage", "colour=\(prefs.brandColorBackground)",
            "--bannerheight", "50",
            "--message",     "\(item.displayName) needs to be updated, but **\(processName)** is currently running.\n\nPlease save your work and quit \(processName) before the timer expires, or click **Skip Update** to postpone this update.",
            "--messagefont", "size=13",
            "--icon",    "caution",
            "--iconsize", "80",
            "--timer",       "\(countdownSeconds)",
            "--button1text", "Skip Update",
            "--button2",
            "--button2text", "Quit \(processName)",
            "--moveable",
            "--height",      "320",
            "--width",       "480",
//            "--checkbox",    "Relaunch after update…",
//            "--checkboxstyle", "regular",
//            "--alwaysreturninput",

        ]
        if prefs.dialogOnTop { args.append("--ontop") }
        // Use the blocking item's app icon as the overlay so the user sees which
        // app is blocking. Fall back to the pkg icon if no app icon is available.
        let overlayIcon = item.iconPath ?? "/System/Library/CoreServices/Installer.app/Contents/Resources/package.icns"
        args += ["--overlayicon", overlayIcon]

        let prompt = launchAsUser(args)
        prompt.waitUntilExit()

        switch prompt.terminationStatus {
        case 0:
            Logger.log("ℹ️ User skipped update for '\(item.label)' (exit \(prompt.terminationStatus))")
            recordBlockingProcessEvent(label: item.label,
                                       type: LabelHistoryEvent.EventType.blockingProcessSkipped,
                                       processName: processName, date: Date())
            return .skip

        case 4:
            // Timer expired — treat as consent to kill
            Logger.log("ℹ️ Countdown expired for '\(processName)' — force-quitting")
            recordBlockingProcessEvent(label: item.label,
                                       type: LabelHistoryEvent.EventType.blockingProcessTimedOut,
                                       processName: processName, date: Date())
            killProcess(named: processName)
            Thread.sleep(forTimeInterval: 2.0)
            return .proceed

        default:
            // Exit 2 = User clicked "Quit <App>" — force-quit and install.
            // Return .proceedRelaunch so the apply loop can reopen the app after the update.
            Logger.log("ℹ️ User chose to quit '\(processName)' — force-quitting")
            recordBlockingProcessEvent(label: item.label,
                                       type: LabelHistoryEvent.EventType.blockingProcessQuit,
                                       processName: processName, date: Date())
            killProcess(named: processName)
            Thread.sleep(forTimeInterval: 2.0)
            return .proceedRelaunch

        }
    }

    private func killProcess(named processName: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-x", processName]
        try? p.run()
        p.waitUntilExit()
    }

    /// Writes a single command line to the swiftDialog command file.
    private func sendCommand(_ command: String) {
        let line = command.hasSuffix("\n") ? command : command + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: commandFileURL.path) {
            if let handle = try? FileHandle(forWritingTo: commandFileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: commandFileURL, options: .atomic)
        }
    }

    /// Launches swiftDialog as the console user via `launchctl asuser`.
    @discardableResult
    private func launchAsUser(_ args: [String], capturingStdoutWith pipe: Pipe? = nil) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["asuser", "\(userUID)", AppConstants.swiftDialogBinaryURL.path] + args
        if let pipe = pipe {
            p.standardOutput = pipe
        }
        p.standardError = Pipe() // prevent stderr from leaking to the log
        do {
            try p.run()
        } catch {
            Logger.log("❌ SwiftDialogController: failed to launch swiftDialog: \(error)")
        }
        return p
    }
}


// MARK: - User progress dialog handle for scan or check

struct UserProgressDialog {
    private let process: Process
    private let commandFileURL: URL
    private let overlayIconPath: String?    // initial dialogIcon — used as overlay during per-label progress
    private let initialOverlayPath: String? // initial overlayicon — restored after the loop completes

    init(process: Process, commandFileURL: URL,
         overlayIconPath: String? = nil, initialOverlayPath: String? = nil) {
        self.process = process
        self.commandFileURL = commandFileURL
        self.overlayIconPath = overlayIconPath
        self.initialOverlayPath = initialOverlayPath
    }

    func update(message: String) {
        send("message: \(message)")
    }

    func updateProgress(_ text: String) {
        send("progresstext: \(text)")
    }

    func setProgress(_ current: Int, of total: Int, label: String, icon: String? = nil) {
        if let icon {
            send("icon: \(icon)")
            if let overlayIconPath { send("overlayicon: \(overlayIconPath)") }
        }
        send("message: \(label)")
        send("progress: \(current)")
        send("progresstext: \(current) of \(total)")
    }

    /// Signals the start of a long download — updates label/icon and switches to indeterminate spinner.
    func beginItem(current: Int, of total: Int, label: String, icon: String? = nil) {
        if let icon {
            send("icon: \(icon)")
            if let overlayIconPath { send("overlayicon: \(overlayIconPath)") }
        }
        send("message: \(label)")
        send("progresstext: \(current) of \(total)")
        send("progress: indeterminate")
    }

    /// Signals the end of a download — restores the determinate bar advanced to `current`.
    func completeItem(current: Int, of total: Int) {
        send("progress: \(current)")
        send("progresstext: \(current) of \(total)")
    }

    /// Restores the icon and overlayicon to what was shown when the dialog first launched.
    func resetIcons() {
        if let overlayIconPath { send("icon: \(overlayIconPath)") }
        if let initialOverlayPath {
            send("overlayicon: \(initialOverlayPath)")
        } else {
            send("overlayicon: none")
        }
    }

    func close() {
        send("progress: complete")
        send("message: Process completed")
        Thread.sleep(forTimeInterval: 3.0)
         
        send("quit:")
        // Give swiftDialog a moment to process the quit command.
        Thread.sleep(forTimeInterval: 1.0)
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: commandFileURL)
    }

    private func send(_ command: String) {
        let line = command.hasSuffix("\n") ? command : command + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: commandFileURL.path),
           let handle = try? FileHandle(forWritingTo: commandFileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: commandFileURL, options: .atomic)
        }
    }
}


// MARK: - Dialog appearance helpers

/// Returns the icon string for the swiftDialog window.
/// Uses the DialogIcon preference when set; otherwise tries to compose a
/// hardware-accurate computer icon. Falls back to an SF symbol string.
private func resolveDialogIcon(prefs: Preferences) -> String {
    let explicit = prefs.dialogIcon
    if !explicit.isEmpty { return explicit }
    if let composed = composedComputerIcon() { return composed }
    return hasBattery
        ? "SF=laptopcomputer.and.arrow.down,weight=regular,palette=gray,red"
        : "SF=desktopcomputer.and.arrow.down,weight=regular,palette=gray,red"
}

/// Composes a PNG icon from the system's hardware-accurate computer image
/// (NSImage.computerName — MacBook, iMac, Mac mini, etc.) with a red
/// download-arrow SF Symbol overlaid at the top center.
/// The result is cached in the patcher config folder so it is only rendered once.
private func composedComputerIcon() -> String? {
    let iconURL = AppConstants.patcherConfigFolderURL.appendingPathComponent("dialog_icon.png")

    if FileManager.default.fileExists(atPath: iconURL.path) {
        return iconURL.path
    }

    let px = 512
    let sz = CGFloat(px)

    guard let computerImage = NSImage(named: NSImage.computerName),
          let bitmapRep = NSBitmapImageRep(
              bitmapDataPlanes: nil,
              pixelsWide: px, pixelsHigh: px,
              bitsPerSample: 8, samplesPerPixel: 4,
              hasAlpha: true, isPlanar: false,
              colorSpaceName: .deviceRGB,
              bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: bitmapRep)
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    // Hardware-accurate computer image fills the canvas
    computerImage.draw(in: NSRect(x: 0, y: 0, width: sz, height: sz),
                       from: .zero, operation: .copy, fraction: 1.0)

    // Red download arrow centered at the top — plain arrow, no circle background
    let badgeSz   = sz * 0.40
    let badgeRect = NSRect(x: (sz - badgeSz) / 2, y: sz - badgeSz * 1.5, width: badgeSz, height: badgeSz)
    let symConfig = NSImage.SymbolConfiguration(pointSize: badgeSz * 0.5, weight: .medium)
        .applying(NSImage.SymbolConfiguration(hierarchicalColor: .systemRed))
    if let arrow = NSImage(systemSymbolName: "arrow.down",
                           accessibilityDescription: nil)?
        .withSymbolConfiguration(symConfig) {
        arrow.draw(in: badgeRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else { return nil }

    do {
        try pngData.write(to: iconURL)
        Logger.log("ℹ️ Composed dialog icon saved to \(iconURL.path)")
        return iconURL.path
    } catch {
        Logger.log("⚠️ Failed to save composed dialog icon: \(error)")
        return nil
    }
}

/// Returns the overlay icon path when UseOverlayIcon is enabled, or nil.
/// Uses the OverlayIcon preference when set; otherwise probes for known MDM
/// agent apps in the same priority order as App-Auto-Patch.
private func resolveOverlayIcon(prefs: Preferences) -> String? {
    guard prefs.useOverlayIcon else { return nil }

    let explicit = prefs.overlayIcon
    if !explicit.isEmpty { return explicit }

    let fm = FileManager.default

    // Jamf — read app path from the Jamf plist (covers non-standard install locations)
    for plistKey in ["self_service_app_path", "self_service_plus_path"] {
        if let appPath = jamfPlistValue(key: plistKey) {
            let icns = appPath + "/Contents/Resources/AppIcon.icns"
            if fm.fileExists(atPath: icns) { return icns }
        }
    }

    // Known MDM / management agent paths, in priority order
    let candidates: [String] = [
        "/Library/Application Support/JAMF/Jamf.app/Contents/Resources/AppIcon.icns",
        "/Applications/Self Service.app/Contents/Resources/AppIcon.icns",
        "/Applications/Self-Service.app/Contents/Resources/AppIcon.icns",
        "/Library/Intune/Microsoft Intune Agent.app/Contents/Resources/AppIcon.icns",
        "/Applications/Company Portal.app/Contents/Resources/AppIcon.icns",
        "/Applications/Manager.app/Contents/Resources/AppIcon.icns",
        "/Library/Addigy/macmanage/MacManage.app/Contents/Resources/atom.icns",
        "/Applications/Workspace ONE Intelligent Hub.app/Contents/Resources/AppIcon.icns",
        "/Applications/Kandji Self Service.app/Contents/Resources/AppIcon.icns",
        "/usr/local/sbin/FileWave.app/Contents/Resources/fwGUI.app/Contents/Resources/kiosk.icns",
        "/System/Applications/App Store.app/Contents/Resources/AppIcon.icns",
        "/Applications/App Store.app/Contents/Resources/AppIcon.icns",
    ]
    return candidates.first { fm.fileExists(atPath: $0) }
}

/// Reads a string value from the Jamf plist, returning nil on any failure.
private func jamfPlistValue(key: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    p.arguments = ["read", "/Library/Preferences/com.jamfsoftware.jamf.plist", key]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError  = Pipe()
    try? p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    let value = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value : nil
}


// MARK: - Help message

/// Builds the markdown help message shown when the user taps the ? button.
private func buildHelpMessage(prefs: Preferences, startISO: String) -> String {
    var msg = "For assistance with this update, please contact **\(prefs.supportTeamName):**"

    let phone   = prefs.supportTeamPhone
    let email   = prefs.supportTeamEmail
    let website = prefs.supportTeamWebsite

    if phone   != "hide" && !phone.isEmpty   { msg += "\n- **Phone:** \(phone)" }
    if email   != "hide" && !email.isEmpty   { msg += "\n- **Email:** \(email)" }
    if website != "hide" && !website.isEmpty {
        let url = (website.hasPrefix("https://") || website.hasPrefix("http://")) ? website : "https://\(website)"
        msg += "\n- **Website:** [\(website)](\(url))"
    }

    msg += "\n\n**Computer Information:**"
    msg += "\n- **Serial Number:** \(macSerialNumber)"
    msg += "\n- **Started:** \(startISO)"

    msg += "\n\n**Software Version:**"
    msg += "\n- **\(AppConstants.patcherFullName):** \(AppConstants.patcherVersion)"
    msg += "\n- **Installomator:** \(installomatorVersion)"
    msg += "\n- **swiftDialog:** \(swiftDialogVersion)"
    msg += "\n- **macOS:** \(macOSVersion)"

    return msg
}

private func buildInfoboxMessage() -> String {

    var msg = "- computer name:\n\(Host.current().localizedName ?? "")"
    msg += "\n- serial number:\n\(macSerialNumber)"
    msg += "\n- macOS version:\n\(macOSVersion)"

    return msg
}

private func buildDeferralInfoboxMessage(daysPending: Int, deferralState: DeferralState) -> String {
    var msg = "**Deferral Status:**\n"
    msg += "- **Days Pending:** \(daysPending)"
    msg += "\n- **User Deferrals:** \(deferralState.userDeferralCount)"
    msg += "\n- **Auto Deferrals:** \(deferralState.automatedDeferralCount)"

    return msg
}
