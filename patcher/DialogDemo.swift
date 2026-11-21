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
            discussion: "Kinds: large, compact, progress, notice, prompt, deferral. Run with sudo; PatcherNotifier must be loaded for the console user. The prompts report what patcher would do but never quit an app or record a deferral."
        )

        @Argument(help: "Which window to show: large, compact, progress, notice, prompt or deferral.")
        var kind: String = "large"

        @Option(name: .long, help: "Seconds each step stays on screen.")
        var step: Double = 1.5

        @Option(name: .long, help: "Seconds on the blocking-app prompt's countdown.")
        var countdown: Int = 60

        @Flag(name: .long, help: "Show the deferral prompt as it looks once the hard deadline is reached.")
        var deadline = false

        func validate() throws {
            guard ["large", "compact", "progress", "notice", "prompt", "deferral"].contains(kind.lowercased()) else {
                throw ValidationError("Unknown kind '\(kind)'. Use large, compact, progress, notice, prompt or deferral.")
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
            case "compact":  runApply(uid: uid, size: .compact)
            case "notice":
                NativeBlockingPrompt(uid: uid, dryRun: true)
                    .notify(processName: "TextEdit", item: Self.sampleItems[1])
                print("Notice closed.")
            case "deferral":
                // Uses the real deferral settings (menu, countdown, automatic action); records nothing.
                let prefs = Preferences()
                var items = Self.sampleItems
                items[3] = ApplyItem(label: "chess", displayName: "Chess",
                                     iconPath: "/System/Applications/Chess.app", isBlocked: true)
                let result = NativeDeferralPrompt(uid: uid).show(
                    items: items, daysPending: 3, hardDeadlineReached: deadline,
                    allowedDeferralMinutes: PatchSchedule(prefs: prefs).allowedDeferralMinutes(daysPending: 3),
                    prefs: prefs)
                switch result {
                case .proceed:                     print("Result: continue and install now.")
                case .deferred(let minutes):       print("Result: deferred by the user for \(formatDeferralDuration(minutes)).")
                case .timedOutDeferred(let minutes): print("Result: countdown ended — auto-deferred for \(formatDeferralDuration(minutes)).")
                case .deadlineForced:              print("Result: hard deadline — install now.")
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
            let window = NativeApplyWindow(uid: uid, size: size)
            let items  = Self.sampleItems
            window.launchProgressDialog(items: items)
            Thread.sleep(forTimeInterval: step)

            for (index, item) in items.enumerated() {
                window.setInProgress(item: item, current: index + 1, total: items.count)
                // Simulated install progress: a package for the first, a copy for the second.
                switch index {
                case 0:  Self.simulate(step) { window.setItemProgress(item: item, fraction: $0, detail: "Installing \(LiveProgress.percent($0))") }
                case 1:
                    window.setItemProgress(item: item, fraction: nil, detail: "Opening disk image…")
                    Thread.sleep(forTimeInterval: step / 2)
                    Self.simulate(step) { window.setItemProgress(item: item, fraction: $0, detail: "Copying \(LiveProgress.percent($0))") }
                default: Thread.sleep(forTimeInterval: step)
                }
                switch index {
                case 2:  window.setFailed(item: item)
                case 3:  window.setSkipped(item: item, reason: "App running")
                default: window.setSuccess(item: item, toVersion: item.newVersion ?? "")
                }
                Thread.sleep(forTimeInterval: step / 2)
            }
            window.complete(applied: 2, skipped: 1, failed: 1)
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

        private func runProgress(uid: uid_t) {
            let items  = Self.sampleItems
            let window = NativeProgressWindow(uid: uid, title: Preferences().appTitle,
                                              message: "Checking \(items.count) applications for available updates…",
                                              total: items.count)
            Thread.sleep(forTimeInterval: step)
            for (index, item) in items.enumerated() {
                window.setProgress(index + 1, of: items.count,
                                   label: "Checking: **\(item.displayName)** for updates…", icon: item.iconPath)
                Thread.sleep(forTimeInterval: step)
            }
            window.beginItem(current: items.count, of: items.count, label: "Downloading: **Safari**…",
                             icon: items[0].iconPath)
            let size: Int64 = 98_400_000
            Self.simulate(step * 2) { fraction in
                window.setItemProgress(fraction, detail: "Downloading \(LiveProgress.percent(fraction)) · "
                    + "\(LiveProgress.bytes(Int64(Double(size) * fraction))) of \(LiveProgress.bytes(size))")
            }
            window.completeItem(current: items.count, of: items.count)
            window.resetIcons()
            window.update(message: "2 updates available to download.")
            window.updateProgress("Complete")
            Thread.sleep(forTimeInterval: step * 2)
            window.close()
        }
    }
}
