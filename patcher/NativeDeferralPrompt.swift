//
//  NativeDeferralPrompt.swift
//  patcher
//
//  The pre-install deferral prompt, drawn by PatcherNotifier: Defer (for a time chosen
//  from the menu) or Continue.
//
//  patcher owns the countdown, which starts once the agent reports the window is on
//  screen. If the window never appears, the apply proceeds, the same as when the prompt
//  couldn't be shown before: running apps are still protected by the blocking-app prompt.
//

import Foundation

final class NativeDeferralPrompt {

    private let uid: uid_t

    init(uid: uid_t) {
        self.uid = uid
    }

    func show(items: [ApplyItem], daysPending: Int, hardDeadlineReached: Bool,
              allowedDeferralMinutes: [Int], prefs: Preferences) -> DeferralPromptResult {
        let menu        = allowedDeferralMinutes
        let defaultMins = DeferralMenu.effectiveDefault(prefs.deferralTimerDefault, menu: menu)
        let seconds     = max(prefs.deferralCountdownSeconds, 1)
        let autoAction  = prefs.deferralAutomaticAction.lowercased()
        let count       = items.count
        let word        = count == 1 ? "update" : "updates"

        var message = "You have **\(count) software \(word)** that \(count == 1 ? "is" : "are") ready to be installed."
        if hardDeadlineReached {
            message += "\n\nInstallation is required — the maximum deferral deadline has been reached."
        } else if daysPending > 0 {
            message += "\n\nThese \(word) have been pending for **\(daysPending) day\(daysPending == 1 ? "" : "s")**."
        }

        let state = DeferralState.load()
        var session = DialogSessionWriter.makeSession(
            kind: .deferral, uid: uid, prefs: prefs, position: prefs.dialogScreenPosition,
            title: prefs.appTitle, message: message, total: 0)
        session.sidePanel = "**Deferral Status**\n"
                          + "Days pending: \(daysPending)\n"
                          + "User deferrals: \(state.userDeferralCount)\n"
                          + "Auto deferrals: \(state.automatedDeferralCount)"
        session.items = items
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .map(Self.row)
        if hardDeadlineReached {
            session.button = DialogSession.Button(title: "Continue", enabled: true)
        } else {
            session.button = DialogSession.Button(
                title: menu.isEmpty ? "Defer (\(formatDeferralDuration(defaultMins)))" : "Defer", enabled: true)
            session.secondaryButton = DialogSession.Button(title: "Continue", enabled: true)
            if !menu.isEmpty {
                session.menu = DialogSession.Menu(
                    title:    "Defer for",
                    options:  menu.map { DialogSession.Menu.Option(value: String($0), label: formatDeferralDuration($0)) },
                    selected: String(defaultMins))
            }
        }

        DialogSessionStore.removeAll(kinds: [.deferral])
        let writer = DialogSessionWriter(session: session)
        let id     = session.id
        DialogSessionStore.removeResponses(id: id)
        defer {
            writer.close()
            DialogSessionStore.removeResponses(id: id)
        }
        Logger.log("ℹ️ Deferral: native prompt shown (\(count) item\(count == 1 ? "" : "s"), \(seconds)s)")

        guard waitForDisplay(id: id) else {
            Logger.log("⚠️ Deferral: prompt was not shown within \(Int(NativeBlockingPrompt.displayTimeout))s — proceeding")
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
                    Logger.log("ℹ️ Deferral: hard deadline — user chose Continue")
                    return .deadlineForced
                }
                // The daemon only accepts a value from the menu; fall back to the default otherwise.
                let minutes = Int(value).flatMap { menu.contains($0) ? $0 : nil } ?? defaultMins
                Logger.log("ℹ️ Deferral: user deferred \(formatDeferralDuration(minutes))")
                return .deferred(minutes: minutes)
            }
            if DialogSessionStore.takeResponse(id: id, .secondary) {
                Logger.log("ℹ️ Deferral: user chose Continue")
                return .proceed
            }
            if DialogSessionStore.takeResponse(id: id, .dismissed) {
                if hardDeadlineReached {
                    Logger.log("ℹ️ Deferral: hard deadline — prompt dismissed, proceeding")
                    return .deadlineForced
                }
                // Dismissing is a deferral, not consent.
                Logger.log("ℹ️ Deferral: user dismissed the prompt — deferring \(formatDeferralDuration(defaultMins))")
                return .deferred(minutes: defaultMins)
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        if hardDeadlineReached {
            Logger.log("ℹ️ Deferral: hard deadline — countdown ended, proceeding")
            return .deadlineForced
        }
        if autoAction == "continue" {
            Logger.log("ℹ️ Deferral: timer expired — auto-continuing")
            return .proceed
        }
        Logger.log("ℹ️ Deferral: timer expired — auto-deferring \(formatDeferralDuration(defaultMins))")
        return .timedOutDeferred(minutes: defaultMins)
    }

    private static func row(_ item: ApplyItem) -> DialogSession.Item {
        var subtitle: String?
        if let installed = item.installedVersion, !installed.isEmpty,
           let new = item.newVersion, !new.isEmpty {
            subtitle = "\(installed) → \(new)"
        }
        return DialogSession.Item(id: item.label, title: item.displayName, subtitle: subtitle,
                                  icon: item.iconPath ?? packageIconPath,
                                  status: item.isBlocked ? .blocked : .ready,
                                  statusText: item.isBlocked ? "Needs to be closed" : "Ready")
    }

    private func waitForDisplay(id: String) -> Bool {
        let deadline = Date().addingTimeInterval(NativeBlockingPrompt.displayTimeout)
        while Date() < deadline, !shutdownRequested {
            if DialogSessionStore.takeResponse(id: id, .displayed) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }
}
