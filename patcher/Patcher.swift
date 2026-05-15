//
//  Patcher.swift
//  patcher
//
//  Created by Gil Burns on 3/9/25.
//

import Foundation
import ArgumentParser

struct Patcher: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patcher",
        abstract: "Scans and patches macOS applications using Installomator.",
        version: AppConstants.patcherVersion,
        subcommands: [Scan.self, Check.self, LightScan.self, Stage.self, StageOnDemand.self, Apply.self, EnsureTool.self, ResetHistory.self, RepairPermissions.self, CleanLogs.self, SendReport.self, TestWebhook.self],
//        defaultSubcommand: Scan.self
    )
}

extension Patcher {
    struct Scan: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Discover installed applications and check for available updates."
        )

        @Flag(name: .long, help: "Show a progress window (used when triggered from PatcherMenu).")
        var userInitiated: Bool = false

        func run() throws {
            Logger.log("Patcher Version: \(AppConstants.patcherVersion)")
            Logger.log("Process ID: \(AppConstants.currentPid)")
            configureLogging()

            setupApplicationSupportFolders()

            let prefs = Preferences()

            if prefs.installomatorLabelsDisable {
                Logger.log("ℹ️ Installomator labels disabled by preference — skipping label setup and updates.")
            } else {
                setupInstallomatorLabels()
                if prefs.installomatorUpdateDisable {
                    Logger.log("ℹ️ Installomator label updates disabled by preference — skipping update check.")
                } else {
                    let dispatchGroup = DispatchGroup()
                    dispatchGroup.enter()
                    installomatorUpdate { dispatchGroup.leave() }
                    dispatchGroup.wait()
                }
            }

            logEnvironmentVariables()

            let total = userInitiated ? countScanLabels() : 0
            let dialog = userInitiated ? SwiftDialogController.launchProgressWindow(
                title:   prefs.appTitle,
                message: "Scanning \(total) application\(total == 1 ? "" : "s") for available updates…",
                total:   total
            ) : nil

            scanAppsForUpdates { current, total, labelName in
                dialog?.setProgress(current, of: total, label: "Scanning \(labelName)…")
            }

            if let dialog {
                let updateCount = countPendingUpdates()
                let summary = updateCount == 0
                    ? "No updates available."
                    : "\(updateCount) update\(updateCount == 1 ? "" : "s") available to download."
                dialog.update(message: summary)
                dialog.updateProgress("Complete")
                Thread.sleep(forTimeInterval: 5.0)
            }
            dialog?.close()
            cleanupAfterRun()
        }
    }
}

extension Patcher {
    struct Check: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check previously discovered applications for available updates."
        )

        @Flag(name: .long, help: "Show a progress window (used when triggered from PatcherMenu).")
        var userInitiated: Bool = false

        func run() throws {
            Logger.log("Patcher Version: \(AppConstants.patcherVersion)")
            Logger.log("Process ID: \(AppConstants.currentPid)")
            configureLogging()

            setupApplicationSupportFolders()

            let prefs = Preferences()

            if prefs.installomatorLabelsDisable {
                Logger.log("ℹ️ Installomator labels disabled by preference — skipping label setup and updates.")
            } else {
                setupInstallomatorLabels()
                if prefs.installomatorUpdateDisable {
                    Logger.log("ℹ️ Installomator label updates disabled by preference — skipping update check.")
                } else {
                    let dispatchGroup = DispatchGroup()
                    dispatchGroup.enter()
                    installomatorUpdate { dispatchGroup.leave() }
                    dispatchGroup.wait()
                }
            }

            logEnvironmentVariables()

            let total = userInitiated ? countCheckLabels() : 0
            let dialog = userInitiated ? SwiftDialogController.launchProgressWindow(
                title:   prefs.appTitle,
                message: "Checking \(total) application\(total == 1 ? "" : "s") for available updates…",
                total:   total
            ) : nil

            checkDiscoveredAppsForUpdates { current, total, displayName in
                dialog?.setProgress(current, of: total, label: "Checking: **\(displayName)**…")
            }

            if let dialog {
                let updateCount = countPendingUpdates()
                let summary = updateCount == 0
                    ? "No updates available."
                    : "\(updateCount) update\(updateCount == 1 ? "" : "s") available to download."
                dialog.update(message: summary)
                dialog.updateProgress("Complete")
                Thread.sleep(forTimeInterval: 5.0)
            }
            dialog?.close()
            cleanupAfterRun()
        }
    }
}

extension Patcher {
    struct LightScan: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "lightScan",
            abstract: "Check uninstalled labels for apps installed by other means, without re-running label scripts."
        )

        @Option(name: .long, help: "Scan only this specific label (used by the Applications folder watcher).")
        var label: String?

        func run() throws {
            Logger.log("Patcher Version: \(AppConstants.patcherVersion)")
            Logger.log("Process ID: \(AppConstants.currentPid)")
            configureLogging()

            setupApplicationSupportFolders()

            if let label {
                Logger.log("🔍 Watcher-triggered scan for '\(label)'")
                scanSingleLabel(label)
            } else {
                checkScannedAppsForInstall()
            }

            cleanupAfterRun()
        }
    }
}

extension Patcher {
    struct Stage: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Download and stage pending updates for previously discovered applications."
        )

        @Option(name: .long, help: "Only stage this label (bypasses bandwidth limit).")
        var label: String?

        func run() throws {
            Logger.log("Patcher Version: \(AppConstants.patcherVersion)")
            Logger.log("Process ID: \(AppConstants.currentPid)")
            configureLogging()

            setupApplicationSupportFolders()
            let bypass = label != nil    // single-label requests bypass bandwidth throttle
            downloadAndStageUpdates(bypassBandwidthLimit: bypass, labelFilter: label)
            cleanupAfterRun()
        }
    }
}

extension Patcher {
    struct StageOnDemand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "stageOnDemand",
            abstract: "Download and stage pending updates immediately, bypassing any configured bandwidth limit."
        )

        func run() throws {
            Logger.log("Patcher Version: \(AppConstants.patcherVersion)")
            Logger.log("Process ID: \(AppConstants.currentPid)")

            setupApplicationSupportFolders()
            downloadAndStageUpdates(bypassBandwidthLimit: true)
            cleanupAfterRun()
        }
    }
}

extension Patcher {
    struct Apply: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install staged updates for previously discovered applications."
        )

        @Option(name: .long, help: "Only apply the staged update for this label.")
        var label: String?

        @Option(name: .long, help: "Days the oldest pending update has been staged (used for deadline enforcement).")
        var daysPending: Int = 0

        @Flag(name: .long, help: "Skip the deferral prompt and go straight to the patching window (used when triggered from PatcherMenu).")
        var userInitiated: Bool = false

        func run() throws {
            Logger.log("Patcher Version: \(AppConstants.patcherVersion)")
            Logger.log("Process ID: \(AppConstants.currentPid)")
            configureLogging()

            setupApplicationSupportFolders()
            applyUpdates(labelFilter: label, daysPending: daysPending, userInitiated: userInitiated)
            cleanupAfterRun()
        }
    }
}

extension Patcher {
    struct ResetHistory: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "resetHistory",
            abstract: "Delete patch history for all labels, or a single label if specified."
        )

        @Argument(help: "Installomator label whose history should be reset. Omit to reset all labels.")
        var label: String?

        func run() throws {
            configureLogging()
            setupApplicationSupportFolders()

            if let label = label {
                resetLabelHistory(label)
            } else {
                resetAllLabelHistory()
            }

            cleanupAfterRun()
        }

        private func resetLabelHistory(_ label: String) {
            let historyURL = LabelHistory.url(for: label)
            guard FileManager.default.fileExists(atPath: historyURL.path) else {
                Logger.log("ℹ️ No history found for '\(label)' — nothing to reset.")
                return
            }
            do {
                try FileManager.default.removeItem(at: historyURL)
                Logger.log("✅ History reset for '\(label)'.")
            } catch {
                Logger.log("❌ Failed to reset history for '\(label)': \(error)")
            }
        }

        private func resetAllLabelHistory() {
            let cacheURL = AppConstants.patcherCacheFolderURL
            guard let labelDirs = try? FileManager.default.contentsOfDirectory(
                at: cacheURL, includingPropertiesForKeys: [.isDirectoryKey]
            ) else {
                Logger.log("ℹ️ Cache directory is empty or missing — nothing to reset.")
                return
            }

            var resetCount = 0
            var errorCount = 0

            for labelDir in labelDirs {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: labelDir.path, isDirectory: &isDir),
                      isDir.boolValue else { continue }

                let historyURL = labelDir.appendingPathComponent(LabelHistory.fileName)
                guard FileManager.default.fileExists(atPath: historyURL.path) else { continue }

                do {
                    try FileManager.default.removeItem(at: historyURL)
                    Logger.log("✅ History reset for '\(labelDir.lastPathComponent)'.")
                    resetCount += 1
                } catch {
                    Logger.log("❌ Failed to reset history for '\(labelDir.lastPathComponent)': \(error)")
                    errorCount += 1
                }
            }

            if resetCount == 0 && errorCount == 0 {
                Logger.log("ℹ️ No history files found — nothing to reset.")
            } else {
                Logger.log("✅ Reset complete — \(resetCount) reset, \(errorCount) failed.")
            }
        }
    }
}

extension Patcher {
    struct RepairPermissions: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "repairPermissions",
            abstract: "Reset ownership (root:wheel) and permissions (dirs 755, files 644) on all patcher data folders."
        )

        func run() throws {
            Logger.log("Patcher Version: \(AppConstants.patcherVersion)")
            Logger.log("Process ID: \(AppConstants.currentPid)")
            configureLogging()

            // Setup application support folders
            setupApplicationSupportFolders()

            repairPermissions()
            
            cleanupAfterRun()
        }
    }
}

extension Patcher {
    struct EnsureTool: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "ensure",
            abstract: "Ensure a specific label is scanned, staged, and applied. Used to bootstrap required tools (e.g. dialog)."
        )

        @Argument(help: "Installomator label name to ensure is installed and current.")
        var label: String

        func run() throws {
            Logger.log("Patcher Version: \(AppConstants.patcherVersion)")
            Logger.log("Process ID: \(AppConstants.currentPid)")
            configureLogging()

            setupApplicationSupportFolders()

            let prefs = Preferences()
            if prefs.installomatorLabelsDisable {
                Logger.log("ℹ️ Installomator labels disabled by preference — skipping label setup.")
            } else {
                setupInstallomatorLabels()
            }

            // Log Info (Verbose only)
            logEnvironmentVariables()

            Logger.log("🔧 Ensuring '\(label)' is current…")

            writeEnsureStatus("Scanning…")
            guard scanSingleLabel(label) else {
                Logger.log("❌ ensure: scan failed for '\(label)' — aborting.")
                cleanupAfterRun()
                return
            }

            writeEnsureStatus("Downloading…")
            downloadAndStageUpdates(bypassBandwidthLimit: true, labelFilter: label)
            writeEnsureStatus("Installing…")
            applyUpdates(labelFilter: label, suppressDialog: true)

            cleanupAfterRun()
        }
    }
}

extension Patcher {
    struct SendReport: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "sendReport",
            abstract: "Send the accumulated webhook report and clear the report log."
        )

        func run() throws {
            Logger.log("Patcher Version: \(AppConstants.patcherVersion)")
            Logger.log("Process ID: \(AppConstants.currentPid)")
            configureLogging()

            let log = loadWebhookReportLog()
            guard !log.isEmpty else {
                Logger.log("ℹ️ Webhook report: nothing accumulated — skipping send.")
                return
            }

            let prefs     = Preferences()
            let threshold = prefs.webhookStageFailureThreshold

            // Apply stage-failure threshold at send time
            let reportableStageFailures = log.stageFailures.filter {
                $0.consecutiveFailures >= threshold
            }

            let successful = log.applyResults.filter(\.success).map {
                WebhookLabelResult(label: $0.label, displayName: $0.displayName,
                                   fromVersion: $0.fromVersion, toVersion: $0.toVersion,
                                   failureReason: nil)
            }
            let applyFailed = log.applyResults.filter { !$0.success }.map {
                WebhookLabelResult(label: $0.label, displayName: $0.displayName,
                                   fromVersion: $0.fromVersion, toVersion: nil,
                                   failureReason: $0.reason ?? "Installation failed")
            }
            let stageFailed = reportableStageFailures.map {
                WebhookLabelResult(label: $0.label, displayName: $0.displayName,
                                   fromVersion: nil, toVersion: nil,
                                   failureReason: "Stage failed (\($0.consecutiveFailures)×): \($0.reason)")
            }
            let failed = applyFailed + stageFailed

            guard !successful.isEmpty || !failed.isEmpty else {
                Logger.log("ℹ️ Webhook report: no reportable events after filtering — skipping send.")
                clearWebhookReportLog()
                return
            }

            Logger.log("📊 Webhook report: \(successful.count) applied, \(applyFailed.count) apply-failed, \(stageFailed.count) stage-failed (threshold \(threshold)×).")

            let device = collectWebhookDeviceInfo()
            sendWebhooks(device: device, successful: successful, failed: failed, prefs: prefs)
            clearWebhookReportLog()
        }
    }
}

extension Patcher {
    struct CleanLogs: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "cleanLogs",
            abstract: "Delete log files in /Library/Logs/Patcher older than a specified number of days."
        )

        @Option(name: .long, help: "Delete log files older than this many days. Defaults to the LogRetentionDays preference (default 90). Pass 0 to skip.")
        var days: Int?

        func run() throws {
            Logger.log("Patcher Version: \(AppConstants.patcherVersion)")
            Logger.log("Process ID: \(AppConstants.currentPid)")
            configureLogging()

            let retention = days ?? Preferences().logRetentionDays
            guard retention > 0 else {
                Logger.log("ℹ️ cleanLogs: retention set to 0 — skipping.")
                return
            }
            Logger.log("ℹ️ cleanLogs: removing logs older than \(retention) days…")
            cleanLogs(olderThanDays: retention)
        }
    }
}

extension Patcher {
    struct TestWebhook: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "testWebhook",
            abstract: "Send a test webhook notification to validate connectivity and message format."
        )

        func run() throws {
            Logger.log("Patcher Version: \(AppConstants.patcherVersion)")
            Logger.log("Process ID: \(AppConstants.currentPid)")
            configureLogging()

            let prefs = Preferences()

            guard !prefs.webhookURLTeams.isEmpty || !prefs.webhookURLSlack.isEmpty else {
                Logger.log("⚠️ No webhook URLs configured (WebhookURLTeams / WebhookURLSlack) — nothing to send.")
                return
            }

            Logger.log("🔍 Collecting device info…")
            let device = collectWebhookDeviceInfo()
            Logger.log("   Computer : \(device.computerName)")
            Logger.log("   Hostname : \(device.hostname)")
            Logger.log("   Serial   : \(device.serialNumber)")
            Logger.log("   User     : \(device.consoleUser.isEmpty ? "(none)" : device.consoleUser)")
            Logger.log("   MDM      : \(device.mdmName)\(device.mdmConsoleURL.map { " — \($0)" } ?? "")")

            let fakeSuccessful: [WebhookLabelResult] = [
                WebhookLabelResult(label: "firefox",   displayName: "Firefox",
                                   fromVersion: "124.0.2",       toVersion: "125.0.1",      failureReason: nil),
                WebhookLabelResult(label: "slack",     displayName: "Slack",
                                   fromVersion: "4.38.2",        toVersion: "4.39.0",       failureReason: nil),
                WebhookLabelResult(label: "zoom",      displayName: "Zoom",
                                   fromVersion: "6.1.5.26030",   toVersion: "6.2.0.31085",  failureReason: nil),
            ]
            let fakeFailed: [WebhookLabelResult] = [
                WebhookLabelResult(label: "microsoftteams", displayName: "Microsoft Teams",
                                   fromVersion: "24065.903.2907", toVersion: nil,
                                   failureReason: "Download failed — teamID mismatch"),
            ]

            Logger.log("📣 Sending test webhook(s)…")
            sendWebhooks(device: device, successful: fakeSuccessful, failed: fakeFailed,
                         prefs: prefs, forceTest: true)
            Logger.log("✅ Test complete.")
        }
    }
}
