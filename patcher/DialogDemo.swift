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
            discussion: "Kinds: large, compact, progress. Run with sudo; PatcherNotifier must be loaded for the console user."
        )

        @Argument(help: "Which window to show: large, compact or progress.")
        var kind: String = "large"

        @Option(name: .long, help: "Seconds each step stays on screen.")
        var step: Double = 1.5

        func validate() throws {
            guard ["large", "compact", "progress"].contains(kind.lowercased()) else {
                throw ValidationError("Unknown kind '\(kind)'. Use large, compact or progress.")
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
            let window = NativeApplyWindow(uid: uid, prompts: nil, size: size)
            let items  = Self.sampleItems
            window.launchProgressDialog(items: items)
            Thread.sleep(forTimeInterval: step)

            for (index, item) in items.enumerated() {
                window.setInProgress(item: item, current: index + 1, total: items.count)
                Thread.sleep(forTimeInterval: step)
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
            Thread.sleep(forTimeInterval: step * 2)
            window.completeItem(current: items.count, of: items.count)
            window.resetIcons()
            window.update(message: "2 updates available to download.")
            window.updateProgress("Complete")
            Thread.sleep(forTimeInterval: step * 2)
            window.close()
        }
    }
}
