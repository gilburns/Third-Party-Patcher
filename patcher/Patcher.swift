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
        subcommands: [Scan.self, Check.self, Stage.self, StageOnDemand.self, Apply.self, EnsureTool.self, ResetHistory.self],
        defaultSubcommand: Scan.self
    )
}

extension Patcher {
    struct Scan: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Discover installed applications and check for available updates."
        )

        func run() throws {
            Logger.log("Patcher Version: \(AppConstants.patcherVersion)")
            Logger.log("Process ID: \(AppConstants.currentPid)")
            configureLogging()

            // Setup application support folders
            setupApplicationSupportFolders()

            let prefs = Preferences()
            if prefs.installomatorLabelsDisable {
                Logger.log("ℹ️ Installomator labels disabled by preference — skipping label setup and updates.")
            } else {
                // Ensure labels exist (handles first-run download)
                setupInstallomatorLabels()

                // Check for label updates unless separately disabled
                if prefs.installomatorUpdateDisable {
                    Logger.log("ℹ️ Installomator label updates disabled by preference — skipping update check.")
                } else {
                    let dispatchGroup = DispatchGroup()
                    dispatchGroup.enter()
                    installomatorUpdate { dispatchGroup.leave() }
                    dispatchGroup.wait()
                }
            }

            // Log Info (Verbose only)
            logEnvironmentVariables()

            // Begin full discovery scan
            scanAppsForUpdates()

            cleanupAfterRun()
        }
    }
}

extension Patcher {
    struct Check: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check previously discovered applications for available updates."
        )

        func run() throws {
            Logger.log("Patcher Version: \(AppConstants.patcherVersion)")
            Logger.log("Process ID: \(AppConstants.currentPid)")
            configureLogging()

            // Setup application support folders
            setupApplicationSupportFolders()

            let prefs = Preferences()
            if prefs.installomatorLabelsDisable {
                Logger.log("ℹ️ Installomator labels disabled by preference — skipping label setup and updates.")
            } else {
                // Ensure labels exist (handles first-run download)
                setupInstallomatorLabels()

                // Check for label updates unless separately disabled
                if prefs.installomatorUpdateDisable {
                    Logger.log("ℹ️ Installomator label updates disabled by preference — skipping update check.")
                } else {
                    let dispatchGroup = DispatchGroup()
                    dispatchGroup.enter()
                    installomatorUpdate { dispatchGroup.leave() }
                    dispatchGroup.wait()
                }
            }

            // Log Info (Verbose only)
            logEnvironmentVariables()

            // Check only previously discovered apps
            checkDiscoveredAppsForUpdates()

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

        func run() throws {
            Logger.log("Patcher Version: \(AppConstants.patcherVersion)")
            Logger.log("Process ID: \(AppConstants.currentPid)")
            configureLogging()

            setupApplicationSupportFolders()
            applyUpdates(labelFilter: label, daysPending: daysPending)
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

            guard scanSingleLabel(label) else {
                Logger.log("❌ ensure: scan failed for '\(label)' — aborting.")
                cleanupAfterRun()
                return
            }

            downloadAndStageUpdates(bypassBandwidthLimit: true, labelFilter: label)
            applyUpdates(labelFilter: label, suppressDialog: true)

            cleanupAfterRun()
        }
    }
}
