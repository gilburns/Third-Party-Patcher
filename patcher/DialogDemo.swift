//
//  DialogDemo.swift
//  patcher
//
//  `patcher dialog-demo` runs a window through a realistic sequence with sample apps,
//  without installing anything, so each window can be checked on a real Mac.
//  Needs root (session files live in a root-owned folder) and a loaded PatcherNotifier.
//

import ArgumentParser
import Foundation

extension Patcher {
    struct DialogDemo: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "dialog-demo",
            abstract: "Show a window with sample data, without installing anything.",
            discussion: "Kinds: large, compact, progress, notice, prompt, deferral, notifications. Run with sudo; PatcherNotifier must be loaded for the console user. The prompts report what patcher would do but never quit an app or record a deferral. 'deferral' opens the apply window to choose, then installs the chosen apps in the same window (add --compact to see it shrink). 'notifications' posts each notification ApplyDialogSize = notifications sends, ending with the Quit & Update prompt."
        )

        @Argument(help: "Which window to show: large, compact, progress, notice, prompt, deferral or notifications.")
        var kind: String = "large"

        @Option(name: .long, help: "Seconds each step stays on screen.")
        var step: Double = 1.5

        @Option(name: .long, help: "Seconds on the blocking-app prompt's countdown (and the Quit & Update notification's).")
        var countdown: Int = 60

        @Flag(name: .long, help: "Show the deferral prompt as it looks once the hard deadline is reached.")
        var deadline = false

        @Flag(name: .long, help: "With 'deferral': continue in the compact window after Install.")
        var compact = false

        func validate() throws {
            guard ["large", "compact", "progress", "notice", "prompt", "deferral", "notifications"].contains(kind.lowercased()) else {
                throw ValidationError("Unknown kind '\(kind)'. Use large, compact, progress, notice, prompt, deferral or notifications.")
            }
            guard getuid() == 0 else {
                throw ValidationError("dialog-demo needs root: run it with sudo.")
            }
        }

        func run() throws {
            guard let uid = PatcherNotifierAgent.windowTargetUID() else {
                throw ValidationError("PatcherNotifier isn't available for the console user (see the log above).")
            }
            switch kind.lowercased() {
            case "progress": runProgress(uid: uid)
            case "notifications": runNotifications()
            case "compact":  runApply(uid: uid, size: .compact)
            case "notice":
                NativeBlockingPrompt(uid: uid, dryRun: true)
                    .notify(processName: "TextEdit", item: Self.sampleItems[1])
                print("Notice closed.")
            case "deferral":
                // Uses the real deferral settings (menu, countdown, automatic action, per-app
                // checkboxes); records nothing.
                let prefs  = Preferences()
                var items  = Self.sampleItems
                items[3]   = ApplyItem(label: "chess", displayName: "Chess",
                                       iconPath: "/System/Applications/Chess.app", isBlocked: true)
                let window = NativeApplyWindow(uid: uid, size: compact ? .compact : .large)
                let result = window.showDeferralPrompt(
                    items: items, daysPending: 3, hardDeadlineReached: deadline,
                    allowedDeferralMinutes: PatchSchedule(prefs: prefs).allowedDeferralMinutes(daysPending: 3),
                    prefs: prefs)
                switch result {
                case .proceed:                       print("Result: install everything now.")
                case .partial(let deferred, let minutes):
                    print("Result: defer \(deferred.joined(separator: ", ")) for \(formatDeferralDuration(minutes)); install the rest now.")
                case .deferred(let minutes):         print("Result: deferred by the user for \(formatDeferralDuration(minutes)).")
                case .timedOutDeferred(let minutes): print("Result: countdown ended — auto-deferred for \(formatDeferralDuration(minutes)).")
                case .deadlineForced:                print("Result: hard deadline — install now.")
                }
                switch result {
                case .deferred, .timedOutDeferred:
                    return
                case .partial(let deferred, _):
                    simulateInstalls(window, items: items.filter { !deferred.contains($0.label) })
                case .proceed, .deadlineForced:
                    simulateInstalls(window, items: items)
                }
            case "prompt":
                let response = NativeBlockingPrompt(uid: uid, dryRun: true)
                    .prompt(processName: "TextEdit", item: Self.sampleItems[1],
                            countdownSeconds: countdown, deferIfScreenLocks: true)
                switch response {
                case .skip:            print("Result: skip the update.")
                case .proceed:         print("Result: quit TextEdit and install; don't reopen it. Nothing was quit.")
                case .proceedRelaunch: print("Result: quit TextEdit, install, then reopen it. Nothing was quit.")
                }
            default:         runApply(uid: uid, size: .large)
            }
        }

        private static let sampleItems: [ApplyItem] = [
            ApplyItem(label: "safari",     displayName: "Safari",     iconPath: "/Applications/Safari.app",
                      installedVersion: "18.1", newVersion: "18.2"),
            ApplyItem(label: "textedit",   displayName: "TextEdit",   iconPath: "/System/Applications/TextEdit.app",
                      installedVersion: "1.19", newVersion: "1.20"),
            ApplyItem(label: "calculator", displayName: "Calculator", iconPath: "/System/Applications/Calculator.app",
                      installedVersion: "11.0", newVersion: "11.1"),
            ApplyItem(label: "chess",      displayName: "Chess",      iconPath: "/System/Applications/Chess.app"),
        ]

        private func runApply(uid: uid_t, size: ApplyDialogSize) {
            simulateInstalls(NativeApplyWindow(uid: uid, size: size), items: Self.sampleItems)
        }

        /// Runs the window through installing `items`: a package, a copy, a failure and a skip.
        private func simulateInstalls(_ window: NativeApplyWindow, items: [ApplyItem]) {
            window.launchProgressDialog(items: items)
            Thread.sleep(forTimeInterval: step)

            var applied = 0, skipped = 0, failed = 0
            for (index, item) in items.enumerated() {
                window.setInProgress(item: item, current: index + 1, total: items.count)
                // Simulated install progress: a package for the first, a copy for the second.
                switch index {
                case 0:  Self.simulate(step) { window.setItemProgress(item: item, detail: .installing(fraction: $0)) }
                case 1:
                    window.setItemProgress(item: item, detail: .openingDiskImage)
                    Thread.sleep(forTimeInterval: step / 2)
                    Self.simulate(step) { window.setItemProgress(item: item, detail: .copying(fraction: $0)) }
                default: Thread.sleep(forTimeInterval: step)
                }
                switch index {
                case 2:  window.setFailed(item: item); failed += 1
                case 3:  window.setSkipped(item: item, reason: .appRunning); skipped += 1
                default: window.setSuccess(item: item, toVersion: item.newVersion ?? ""); applied += 1
                }
                Thread.sleep(forTimeInterval: step / 2)
            }
            window.complete(applied: applied, skipped: skipped, failed: failed)
            window.waitForDialog(timeout: 60)
            print("Done. The large window stays until you click Done, or 60 seconds pass.")
        }

        /// Calls `report` with fractions from 0 to 1 over `seconds`, as a download or install would.
        private static func simulate(_ seconds: Double, report: (Double) -> Void) {
            let steps = 20
            for i in 0...steps {
                report(Double(i) / Double(steps))
                Thread.sleep(forTimeInterval: seconds / Double(steps))
            }
        }

        /// Queues each notification-mode event in turn. PatcherNotifier holds a replacement
        /// until the notification it replaces has been up a few seconds. Quit & Update and
        /// closing the prompt are reported, never acted on.
        private func runNotifications() {
            let items = Self.sampleItems
            func post(_ kind: PatcherNotificationEvent.Kind, _ title: DialogText, _ body: DialogText,
                      item: ApplyItem? = nil, id: String? = nil, sound: Bool = false,
                      category: String? = nil, lifetime: TimeInterval = 60 * 60) -> PatcherNotificationEvent {
                let event = PatcherNotificationEvent(kind: kind, title: title, body: body, threadID: "demo",
                                                     playSound: sound, iconPath: item?.iconPath, label: item?.label,
                                                     replaceID: id.map { "demo.\($0)" }, category: category,
                                                     lifetime: lifetime)
                UserNotificationQueue.enqueue(event)
                return event
            }
            func pause(_ factor: Double = 1) { Thread.sleep(forTimeInterval: step * factor) }

            let safari = items[0]
            _ = post(.applyInProgress, .updatingAppTitle(app: safari.displayName),
                     .appBeingUpdated(app: safari.displayName), item: safari, id: safari.label)
            pause(2)
            _ = post(.applyInstalled, .appUpdatedTitle(app: safari.displayName),
                     .appWasUpdated(app: safari.displayName, version: safari.newVersion, background: false),
                     item: safari, id: safari.label)
            pause()
            let textEdit = items[1]
            _ = post(.applyFailed, .appUpdateFailedTitle(app: textEdit.displayName),
                     .updateWillBeRetried(app: textEdit.displayName), item: textEdit, id: textEdit.label)
            pause()
            let calculator = items[2]
            _ = post(.blockingNotify, .updatePendingTitle(app: calculator.displayName),
                     .quitWhenConvenient(app: calculator.displayName), item: calculator, id: calculator.label,
                     sound: true)
            pause()
            _ = post(.quietApplyInstalled, .appUpdatedTitle(app: items[3].displayName),
                     .appWasUpdated(app: items[3].displayName, version: nil, background: true), item: items[3])
            pause()
            _ = post(.quietApplyInstalled, .appsUpdatedTitle(count: 3),
                     .appList(["Safari 18.2", "Calculator 11.1", "Chess"]))
            pause()

            let chess = items[3]
            let prompt = post(.blockingPrompt, .appUpdateReadyTitle(app: chess.displayName),
                              .quitAndUpdatePrompt(process: chess.displayName, seconds: countdown),
                              item: chess, id: chess.label, sound: true,
                              category: PatcherNotificationEvent.blockingPromptCategory,
                              lifetime: TimeInterval(countdown) + 60)
            print("Waiting up to \(countdown)s for the Quit & Update notification…")
            let deadline = Date().addingTimeInterval(TimeInterval(countdown))
            var response: NotificationResponseAction?
            while response == nil, Date() < deadline {
                response = UserNotificationQueue.takeResponse(eventID: prompt.id)
                if response == nil { Thread.sleep(forTimeInterval: 1) }
            }
            switch response {
            case .quitAndUpdate: print("Result: Quit & Update. Nothing was quit.")
            case .skip:          print("Result: notification closed — skip the update.")
            case nil:            print("Result: no response — patcher would quit Chess and install. Nothing was quit.")
            }
            _ = post(.withdraw, .verbatim(""), .verbatim(""), id: chess.label, lifetime: 60 * 60)
        }

        private func runProgress(uid: uid_t) {
            let items  = Self.sampleItems
            let window = NativeProgressWindow(uid: uid, title: .verbatim(Preferences().appTitle),
                                              message: .checkingApps(count: items.count),
                                              total: items.count)
            Thread.sleep(forTimeInterval: step)
            for (index, item) in items.enumerated() {
                window.setProgress(index + 1, of: items.count,
                                   label: .checkingApp(item.displayName), icon: item.iconPath)
                Thread.sleep(forTimeInterval: step)
            }
            window.beginItem(current: items.count, of: items.count, label: .downloadingApp(items[0].displayName),
                             icon: items[0].iconPath)
            let size: Int64 = 98_400_000
            Self.simulate(step * 2) { fraction in
                window.setItemProgress(.downloading(fraction: fraction,
                                                    received: Int64(Double(size) * fraction), total: size))
            }
            window.completeItem(current: items.count, of: items.count)
            window.resetIcons()
            window.update(message: .updatesAvailableToDownload(count: 2))
            window.updateProgress(.complete)
            Thread.sleep(forTimeInterval: step * 2)
            window.close()
        }
    }
}
