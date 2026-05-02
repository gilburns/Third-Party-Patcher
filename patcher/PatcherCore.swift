//
//  PatcherCore.swift
//  patcher
//
//  Created by Gil Burns on 3/9/25.
//

import Foundation
import ArgumentParser

// MARK: - Setup Folders
func configureLogging() {
    Logger.isVerbose = Preferences().logVerbose
}

func setupApplicationSupportFolders() {
    Logger.log("Checking for and creating application support folders...")
    let folders = [
        AppConstants.patcherFolderURL.path,
        AppConstants.patcherCacheFolderURL.path,
        AppConstants.patcherConfigFolderURL.path,
        AppConstants.patcherDiscoveredFolderURL.path,
        AppConstants.installomatorFolderURL.path,
        AppConstants.managedLabelsFolderURL.path,
        AppConstants.managedIconsFolderURL.path,
        AppConstants.managedMetadataFolderURL.path,
        AppConstants.patcherTempFolderURL.path
    ]
    
    // Create required folders if they don't exist
    for folder in folders {
        if !FileManager.default.fileExists(atPath: folder) {
            do {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [
                    .posixPermissions: 0o755,
                    .ownerAccountID: NSNumber(value: 0),
                    .groupOwnerAccountID: NSNumber(value: 0)
                ])
                Logger.log("Created folder: \(folder)")
            } catch {
                Logger.log("Failed to create folder: \(folder), error: \(error)")
            }
        }
    }
}

// MARK: - Repair Permissions

func repairPermissions() {
    let root = AppConstants.patcherFolderURL
    let fm = FileManager.default

    guard fm.fileExists(atPath: root.path) else {
        Logger.log("❌ Patcher data folder not found: \(root.path)")
        return
    }

    Logger.log("🔧 Repairing ownership and permissions under \(root.path)…")

    var fixedCount = 0
    var errorCount = 0

    func applyAttributes(to url: URL, isDirectory: Bool) {
        let mode: Int = isDirectory ? 0o755 : 0o644
        do {
            try fm.setAttributes([
                .posixPermissions: mode,
                .ownerAccountID: NSNumber(value: 0),
                .groupOwnerAccountID: NSNumber(value: 0)
            ], ofItemAtPath: url.path)
            Logger.verbose("  \(isDirectory ? "755" : "644") root:wheel  \(url.path)")
            fixedCount += 1
        } catch {
            Logger.log("⚠️ Could not repair \(url.lastPathComponent): \(error.localizedDescription)")
            errorCount += 1
        }
    }

    // Apply to the root folder itself
    applyAttributes(to: root, isDirectory: true)

    guard let enumerator = fm.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: []
    ) else {
        Logger.log("❌ Failed to enumerate \(root.path)")
        return
    }

    for case let url as URL in enumerator {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        applyAttributes(to: url, isDirectory: isDir)
    }

    if errorCount == 0 {
        Logger.log("✅ Repair complete — \(fixedCount) items set to root:wheel (dirs 755, files 644).")
    } else {
        Logger.log("⚠️ Repair complete — \(fixedCount) items updated, \(errorCount) errors.")
    }
}

// MARK: - Installomator Labels Setup
func setupInstallomatorLabels() {
    // Check if Installomator labels exist
    Logger.log("Checking for Installomator labels...")
    if !FileManager.default.fileExists(atPath: AppConstants.installomatorLabelsFolderURL.path) {
        Logger.log("Installomator labels not found. Downloading...")
        let dispatchGroup = DispatchGroup()
        
        dispatchGroup.enter()
        installomatorUpdate {
            dispatchGroup.leave()
        }
        
        // **Wait here before exiting function**
        dispatchGroup.wait()
    }
    Logger.log("Installomator labels are set up.")
}

// MARK: - Installomator Update
func installomatorUpdate(completion: @escaping () -> Void) {
    InstallomatorLabels.compareInstallomatorVersion { isUpToDate, statusMessage in
        Logger.log(statusMessage)
        if !isUpToDate {
            Logger.log("Updating Installomator labels...")
            InstallomatorLabels.installInstallomatorLabels { _, message in
                Logger.log(message)
                completion()
            }
        } else {
            completion()
        }
    }
}

// MARK: - Environment
func logEnvironmentVariables() {
    
    let sysInfo = getEnvironmentVars()
    Logger.verbose("📦 Environment variables:")
    
    for (key, value) in sysInfo {
        Logger.verbose("\(key): \(value)")
    }
}

/// MARK: - Progress pre-count helpers

/// Returns the number of label files that scan will process (for progress bar sizing).
func countScanLabels() -> Int { buildLabelFileList().count }

/// Returns the number of discovered plists that check will process (for progress bar sizing).
func countCheckLabels() -> Int {
    (try? FileManager.default.contentsOfDirectory(
        at: AppConstants.patcherDiscoveredFolderURL, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "plist" }.count) ?? 0
}

/// Returns the number of discovered plists with updateStatus == "updateRequired".
func countPendingUpdates() -> Int {
    let fm = FileManager.default
    guard let plists = try? fm.contentsOfDirectory(
        at: AppConstants.patcherDiscoveredFolderURL, includingPropertiesForKeys: nil
    ) else { return 0 }

    let prefs = Preferences()
    let stageBroken = Set(loadStageBrokenState().labels)
    let applyBrokenVersions = loadApplyBrokenState().brokenVersions
    let ignoreHomeFolder = prefs.ignoreAppsInHomeFolder
    let throttleDays = prefs.versionMismatchThrottleDays

    // Load staged labels so we don't double-count items already downloaded
    let stagedLabels: Set<String> = {
        guard let dirs = try? fm.contentsOfDirectory(
            at: AppConstants.patcherCacheFolderURL, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return Set(dirs.compactMap { url -> String? in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            let meta = url.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: meta),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["stagedTimestamp"] != nil else { return nil }
            return url.lastPathComponent
        })
    }()

    return plists.filter { $0.pathExtension == "plist" }.filter { url in
        let label = url.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let status = dict["updateStatus"] as? String, status == "updateRequired"
        else { return false }

        guard !stagedLabels.contains(label) else { return false }
        guard !stageBroken.contains(label) else { return false }

        let appNewVersion = dict["appNewVersion"] as? String ?? ""

        if let brokenVersion = applyBrokenVersions[label],
           appNewVersion == brokenVersion || appNewVersion.isEmpty { return false }

        if ignoreHomeFolder,
           let foundInstalls = dict["foundInstalls"] as? [[String: Any]],
           !foundInstalls.isEmpty,
           foundInstalls.allSatisfy({ ($0["path"] as? String ?? "").hasPrefix("/Users/") }) { return false }

        if unknownVersionThrottleActive(label: label, intervalDays: throttleDays, currentAppNewVersion: appNewVersion) { return false }

        return true
    }.count
}

// MARK: - Start Scanning
func scanAppsForUpdates(progressHandler: ((Int, Int, String) -> Void)? = nil) {
    let scanStart = Date()
    let iso = ISO8601DateFormatter()
    Logger.log("🔍 Scan started at \(iso.string(from: scanStart))")

    let preferences = Preferences()
    Logger.log("📋 Preferences source: \(preferences.source)")

    let ignoredPatterns = preferences.ignoredLabels
    if !ignoredPatterns.isEmpty {
        Logger.log("⏭️ Ignored label patterns: \(ignoredPatterns.joined(separator: ", "))")
    }

    let requiredLabels = Set(preferences.requiredLabels)
    if !requiredLabels.isEmpty {
        Logger.log("⭐ Required labels: \(requiredLabels.sorted().joined(separator: ", "))")
    }

    // Load Installomator version and previously broken labels
    let currentInstallomatorVersion = loadEffectiveLabelsVersion()
    Logger.log("📦 Labels version: \(currentInstallomatorVersion)")

    let previousBrokenState = loadPreviousBrokenState()
    let brokenAutoSkip: Set<String> = previousBrokenState.installomatorVersion == currentInstallomatorVersion
        ? Set(previousBrokenState.labels)
        : []
    if !brokenAutoSkip.isEmpty {
        Logger.log("⚠️ Auto-skipping \(brokenAutoSkip.count) label(s) broken in version \(currentInstallomatorVersion): \(brokenAutoSkip.sorted().joined(separator: ", "))")
    }

    do {
        // Retrieve and filter ".sh" files, merging managed label overrides/additions
        let shFiles = buildLabelFileList()

        guard !shFiles.isEmpty else {
            Logger.log("❌ No label files found — nothing to scan. Add managed labels or enable Installomator labels.")
            return
        }

        let scriptPath = ZshScriptRunner.writeScriptToFile(AppConstants.processLabelZsh)!.path

        var scannedCount = 0
        var ignoredCount = 0
        var brokenSkippedCount = 0
        var newlyBrokenLabels: [String] = []

        // Iterate through each script file
        for fileURL in shFiles {
            let label = fileURL.deletingPathExtension().lastPathComponent

            if !ignoredPatterns.isEmpty && labelIsIgnored(label, patterns: ignoredPatterns) {
                if requiredLabels.contains(label) {
                    Logger.log("⭐ \(label) is required — overriding ignored pattern")
                } else {
                    Logger.log("⏭️ Ignoring label: \(label)")
                    ignoredCount += 1
                    removeDiscoveredPlistIfPresent(label: label)
                    continue
                }
            }

            if brokenAutoSkip.contains(label) {
                if requiredLabels.contains(label) {
                    Logger.log("⭐ \(label) is required — overriding broken-skip")
                } else {
                    Logger.log("--------------------------------------------------")
                    Logger.log("⚠️ Skipping previously broken label: \(label)")
                    brokenSkippedCount += 1
                    removeDiscoveredPlistIfPresent(label: label)
                    continue
                }
            }

            scannedCount += 1
            progressHandler?(scannedCount, shFiles.count, label)
            let filePath = fileURL.path
            Logger.log("--------------------------------------------------")
            Logger.log("📜 Processing script: \(fileURL.lastPathComponent)")

            // Run the script and capture output
            guard let output = ZshScriptRunner.runScript(at: scriptPath, arguments: [filePath]),
                  let jsonDict = parseScriptOutput(output) else {
                Logger.log("❌ Failed to run script or parse JSON for \(filePath)")
                newlyBrokenLabels.append(label)
                continue
            }

            guard validateLabelRequiredKeys(jsonDict, label: label) else {
                newlyBrokenLabels.append(label)
                continue
            }

            // Now we have jsonDict containing parsed output from the script
            processScriptData(jsonDict)
        }

        // Build the persistent broken label list:
        // - Same Installomator version: carry forward skipped labels and merge any newly broken ones
        // - New Installomator version: start fresh with only what broke this scan
        let updatedBrokenLabels: [String]
        if previousBrokenState.installomatorVersion == currentInstallomatorVersion {
            updatedBrokenLabels = Array(Set(previousBrokenState.labels).union(newlyBrokenLabels)).sorted()
        } else {
            updatedBrokenLabels = newlyBrokenLabels.sorted()
        }

        let scanEnd = Date()
        let duration = scanEnd.timeIntervalSince(scanStart)
        Logger.log("✅ Scan complete — \(scannedCount) scanned, \(ignoredCount) ignored, \(brokenSkippedCount) broken-skipped, \(newlyBrokenLabels.count) newly broken, \(String(format: "%.2f", duration))s")
        if !newlyBrokenLabels.isEmpty {
            Logger.log("⚠️ Newly broken labels: \(newlyBrokenLabels.joined(separator: ", "))")
        }
        if !updatedBrokenLabels.isEmpty {
            Logger.log("📋 Cumulative broken labels (\(updatedBrokenLabels.count)): \(updatedBrokenLabels.joined(separator: ", "))")
        }

        updateConfigJSON([
            "lastScanFullStart": iso.string(from: scanStart),
            "lastScanFullEnd": iso.string(from: scanEnd),
            "lastScanFullDurationSeconds": duration,
            "lastScanFullInstallomatorVersion": currentInstallomatorVersion,
            "lastScanFullLabelCount": scannedCount,
            "lastScanFullIgnoredCount": ignoredCount,
            "lastScanFullBrokenSkippedCount": brokenSkippedCount,
            "lastScanBrokenLabels": updatedBrokenLabels
        ])

    } catch {
        Logger.log("Error accessing folder: \(error)")
    }
}

// MARK: - Scan Single Label (used by EnsureTool)

/// Evaluates one Installomator label and writes its discovered plist.
/// Does NOT update scan-phase config.json stats or touch the broken-label list.
/// Returns true if the label was found, run, and processed without error.
@discardableResult
func scanSingleLabel(_ labelName: String) -> Bool {
    guard let labelFileURL = resolveLabel(name: labelName) else {
        Logger.log("❌ scanSingleLabel: no label file found for '\(labelName)'")
        return false
    }

    guard let scriptPath = ZshScriptRunner.writeScriptToFile(AppConstants.processLabelZsh)?.path else {
        Logger.log("❌ scanSingleLabel: failed to write process script")
        return false
    }

    Logger.log("📜 scanSingleLabel: processing '\(labelName)'")

    guard let output = ZshScriptRunner.runScript(at: scriptPath, arguments: [labelFileURL.path]),
          let jsonDict = parseScriptOutput(output) else {
        Logger.log("❌ scanSingleLabel: script run or JSON parse failed for '\(labelName)'")
        return false
    }

    guard validateLabelRequiredKeys(jsonDict, label: labelName) else {
        Logger.log("❌ scanSingleLabel: key validation failed for '\(labelName)'")
        return false
    }

    processScriptData(jsonDict, forceInstall: true)
    return true
}


/// MARK: - Check Discovered Apps
func checkDiscoveredAppsForUpdates(progressHandler: ((Int, Int, String) -> Void)? = nil) {
    let checkStart = Date()
    let iso = ISO8601DateFormatter()
    Logger.log("🔎 Update check started at \(iso.string(from: checkStart))")

    let preferences = Preferences()
    Logger.log("📋 Preferences source: \(preferences.source)")

    let ignoredPatterns = preferences.ignoredLabels
    if !ignoredPatterns.isEmpty {
        Logger.log("⏭️ Ignored label patterns: \(ignoredPatterns.joined(separator: ", "))")
    }

    let requiredLabels = Set(preferences.requiredLabels)
    if !requiredLabels.isEmpty {
        Logger.log("⭐ Required labels: \(requiredLabels.sorted().joined(separator: ", "))")
    }

    let currentInstallomatorVersion = loadEffectiveLabelsVersion()
    Logger.log("📦 Labels version: \(currentInstallomatorVersion)")

    let previousBrokenState = loadPreviousBrokenState()
    let brokenAutoSkip: Set<String> = previousBrokenState.installomatorVersion == currentInstallomatorVersion
        ? Set(previousBrokenState.labels)
        : []
    if !brokenAutoSkip.isEmpty {
        Logger.log("⚠️ Auto-skipping \(brokenAutoSkip.count) label(s) broken in version \(currentInstallomatorVersion): \(brokenAutoSkip.sorted().joined(separator: ", "))")
    }

    let discoveredFolderURL = AppConstants.patcherDiscoveredFolderURL
    let fileManager = FileManager.default

    do {
        // Derive label list from previously discovered plists
        let discoveredLabels = try fileManager.contentsOfDirectory(at: discoveredFolderURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "plist" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()

        guard !discoveredLabels.isEmpty else {
            Logger.log("ℹ️ No previously discovered apps found — run 'patcher scan' first.")
            return
        }

        Logger.log("📋 \(discoveredLabels.count) previously discovered label(s) to check.")

        let scriptPath = ZshScriptRunner.writeScriptToFile(AppConstants.processLabelZsh)!.path

        var checkedCount = 0
        var ignoredCount = 0
        var brokenSkippedCount = 0
        var newlyBrokenLabels: [String] = []

        for label in discoveredLabels {
            if !ignoredPatterns.isEmpty && labelIsIgnored(label, patterns: ignoredPatterns) {
                if requiredLabels.contains(label) {
                    Logger.log("⭐ \(label) is required — overriding ignored pattern")
                } else {
                    Logger.log("⏭️ Ignoring label: \(label)")
                    ignoredCount += 1
                    removeDiscoveredPlistIfPresent(label: label)
                    continue
                }
            }

            if brokenAutoSkip.contains(label) {
                if requiredLabels.contains(label) {
                    Logger.log("⭐ \(label) is required — overriding broken-skip")
                } else {
                    Logger.log("--------------------------------------------------")
                    Logger.log("⚠️ Skipping previously broken label: \(label)")
                    brokenSkippedCount += 1
                    continue
                }
            }

            guard let labelFileURL = resolveLabel(name: label) else {
                Logger.log("⚠️ Label file not found for discovered app '\(label)' — removing discovered plist.")
                removeDiscoveredPlistIfPresent(label: label)
                continue
            }

            checkedCount += 1
            let displayName: String = {
                let plistURL = AppConstants.patcherDiscoveredFolderURL.appendingPathComponent("\(label).plist")
                if let data = try? Data(contentsOf: plistURL),
                   let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                   let name = dict["name"] as? String, !name.isEmpty { return name }
                return label
            }()
            progressHandler?(checkedCount, discoveredLabels.count, displayName)
            Logger.log("--------------------------------------------------")
            Logger.log("🔎 Checking: \(label).sh")

            guard let output = ZshScriptRunner.runScript(at: scriptPath, arguments: [labelFileURL.path]),
                  let jsonDict = parseScriptOutput(output) else {
                Logger.log("❌ Failed to run script or parse JSON for \(label)")
                newlyBrokenLabels.append(label)
                continue
            }

            guard validateLabelRequiredKeys(jsonDict, label: label) else {
                newlyBrokenLabels.append(label)
                continue
            }

            processScriptData(jsonDict)
        }

        // Merge broken labels with same version carry-forward logic
        let updatedBrokenLabels: [String]
        if previousBrokenState.installomatorVersion == currentInstallomatorVersion {
            updatedBrokenLabels = Array(Set(previousBrokenState.labels).union(newlyBrokenLabels)).sorted()
        } else {
            updatedBrokenLabels = newlyBrokenLabels.sorted()
        }

        let checkEnd = Date()
        let duration = checkEnd.timeIntervalSince(checkStart)
        Logger.log("--------------------------------------------------")
        Logger.log("✅ Update check complete — \(checkedCount) checked, \(ignoredCount) ignored, \(brokenSkippedCount) broken-skipped, \(newlyBrokenLabels.count) newly broken, \(String(format: "%.2f", duration))s")
        if !newlyBrokenLabels.isEmpty {
            Logger.log("⚠️ Newly broken labels: \(newlyBrokenLabels.joined(separator: ", "))")
        }
        if !updatedBrokenLabels.isEmpty {
            Logger.log("📋 Cumulative broken labels (\(updatedBrokenLabels.count)): \(updatedBrokenLabels.joined(separator: ", "))")
        }

        updateConfigJSON([
            "lastCheckStart": iso.string(from: checkStart),
            "lastCheckEnd": iso.string(from: checkEnd),
            "lastCheckDurationSeconds": duration,
            "lastCheckInstallomatorVersion": currentInstallomatorVersion,
            "lastCheckLabelCount": checkedCount,
            "lastCheckIgnoredCount": ignoredCount,
            "lastCheckBrokenSkippedCount": brokenSkippedCount,
            "lastScanBrokenLabels": updatedBrokenLabels
        ])

    } catch {
        Logger.log("❌ Error during update check: \(error)")
    }
}


private func labelIsIgnored(_ label: String, patterns: [String]) -> Bool {
    patterns.contains { NSPredicate(format: "self LIKE[c] %@", $0).evaluate(with: label) }
}

func parseScriptOutput(_ output: String) -> [String: Any]? {
    // Convert JSON string to a dictionary
//    Logger.log("Output: \(output)")
    if let jsonData = output.data(using: .utf8) {
        do {
            if let jsonDict = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] {
//                Logger.log("JSON Parsed Successfully: \(jsonDict)")
                return jsonDict
            }
        } catch {
            Logger.log("Failed to parse JSON output: \(error)")
        }
    }
    return nil
}

enum UpdateStatus: String {
    case updateRequired
    case upToDate
    case wouldDowngrade
    case unknown
}

struct FoundInstall {
    let path: String
    let version: String
    let discoveryMethod: String
}

func validateLabelRequiredKeys(_ jsonDict: [String: Any], label: String) -> Bool {
    let requiredKeys = ["name", "type", "downloadURL", "expectedTeamID"]
    let missing = requiredKeys.filter { key in
        guard let value = jsonDict[key] as? String else { return true }
        return value.isEmpty
    }
    guard missing.isEmpty else {
        Logger.log("⚠️ Broken label \(label) — missing required keys: \(missing.joined(separator: ", "))")
        return false
    }
    return true
}


func processScriptData(_ jsonDict: [String: Any], forceInstall: Bool = false) {
    // Process the JSON data immediately after each script runs
    if let label = jsonDict["label"] as? String,
       let name = jsonDict["name"] as? String,
       let appCustomVersion = jsonDict["appCustomVersion"] as? String,
       let appName = jsonDict["appName"] as? String,
       let appNewVersionRaw = jsonDict["appNewVersion"] as? String,
       let archiveName = jsonDict["archiveName"] as? String,
       let blockingProcesses = jsonDict["blockingProcesses"] as? [String],
       let cliArguments = jsonDict["CLIArguments"] as? String,
       let cliInstaller = jsonDict["CLIInstaller"] as? String,
       let curlOptions = jsonDict["curlOptions"] as? String,
       let downloadURL = jsonDict["downloadURL"] as? String,
       let expectedTeamID = jsonDict["expectedTeamID"] as? String,
       let installerTool = jsonDict["installerTool"] as? String,
       let packageID = jsonDict["packageID"] as? String,
       let pkgName = jsonDict["pkgName"] as? String,
       let targetDir = jsonDict["targetDir"] as? String,
       let timeStamp = jsonDict["timeStamp"] as? String,
       let type = jsonDict["type"] as? String,
       let updateTool = jsonDict["updateTool"] as? String,
       let updateToolArguments = jsonDict["updateToolArguments"] as? String,
       let updateToolRunAsCurrentUser = jsonDict["updateToolRunAsCurrentUser"] as? String,
       let versionKey = jsonDict["versionKey"] as? String
    {
        let appNewVersion = sanitizedVersion(appNewVersionRaw)

        Logger.verbose("label: \(label)")
        Logger.verbose("name: \(name)")
        Logger.verbose("appCustomVersion: \(appCustomVersion)")
        Logger.verbose("appName: \(appName)")
        Logger.verbose("appNewVersion: \(appNewVersion) (raw: \(appNewVersionRaw))")
        Logger.verbose("archiveName: \(archiveName)")
        Logger.verbose("blockingProcesses: \(blockingProcesses)")
        Logger.verbose("cliArguments: \(cliArguments)")
        Logger.verbose("cliInstaller: \(cliInstaller)")
        Logger.verbose("curlOptions: \(curlOptions)")
        Logger.verbose("downloadURL: \(downloadURL)")
        Logger.verbose("expectedTeamID: \(expectedTeamID)")
        Logger.verbose("installerTool: \(installerTool)")
        Logger.verbose("packageID: \(packageID)")
        Logger.verbose("pkgName: \(pkgName)")
        Logger.verbose("targetDir: \(targetDir)")
        Logger.verbose("timeStamp: \(timeStamp)")
        Logger.verbose("type: \(type)")
        Logger.verbose("updateTool: \(updateTool)")
        Logger.verbose("updateToolArguments: \(updateToolArguments)")
        Logger.verbose("updateToolRunAsCurrentUser: \(updateToolRunAsCurrentUser)")
        Logger.verbose("versionKey: \(versionKey)")
        
        
        let installedVersion: String?
        var foundInstalls: [FoundInstall]? = nil

        if !appCustomVersion.isEmpty {
            Logger.log("🔍 appCustomVersion resolved: \(appCustomVersion)")
            installedVersion = appCustomVersion
        } else if !packageID.isEmpty {
            Logger.log("🔍 Checking pkg receipt for: \(packageID)")
            installedVersion = getPackageVersion(packageID: packageID)
        } else {
            let appWithExtension: String
            if !appName.isEmpty {
                appWithExtension = appName
            } else {
                appWithExtension = name + ".app"
            }
            Logger.log("🔍 Checking for updates for: \(appWithExtension)...")
            let installs = getApplicationVersion(appWithExtension: appWithExtension, versionKey: versionKey, targetDir: targetDir)
            installedVersion = installs?.first?.version
            foundInstalls = installs
        }

        guard let installedVersion else {
            if forceInstall && !appNewVersion.isEmpty {
                // App/pkg not installed — write plist so staging will download and install it.
                Logger.log("⬆️ \(label) not installed — marking as updateRequired (forceInstall)")
                var cleanDict = jsonDict
                cleanDict["appNewVersion"] = appNewVersion
                writeDiscoveredPlist(label: label, jsonDict: cleanDict,
                                     installedVersion: "", updateStatus: .updateRequired,
                                     foundInstalls: nil)
            }
            return
        }

        let updateStatus: UpdateStatus
        if appNewVersion.isEmpty {
            updateStatus = .unknown
        } else {
            switch appNewVersion.compare(installedVersion, options: .numeric) {
            case .orderedDescending:
                updateStatus = .updateRequired     // available is numerically newer
            case .orderedSame:
                updateStatus = .upToDate
            case .orderedAscending:
                // available sorts before installed — likely a stale/broken label scrape
                if appNewVersion == installedVersion {
                    updateStatus = .upToDate       // identical strings, just in case
                } else {
                    updateStatus = .wouldDowngrade
                }
            }
        }

        switch updateStatus {
        case .updateRequired:
            Logger.log("⬆️ Update required: \(installedVersion) → \(appNewVersion)")
            recordUpdateFoundIfNeeded(label: label, installedVersion: installedVersion, availableVersion: appNewVersion, date: Date())
        case .upToDate:
            Logger.log("👍 Up to date: \(installedVersion)")
        case .wouldDowngrade:
            Logger.log("⏬ Skipping \(label) — available \(appNewVersion) is older than installed \(installedVersion)")
        case .unknown:
            Logger.log("❓ Update status unknown — no latest version info available")
        }

        var cleanDict = jsonDict
        cleanDict["appNewVersion"] = appNewVersion
        writeDiscoveredPlist(label: label, jsonDict: cleanDict, installedVersion: installedVersion, updateStatus: updateStatus, foundInstalls: foundInstalls)
    } else {
        Logger.log("⚠️ Missing expected keys in JSON output")
    }
}



func loadInstallomatorVersion() -> String {
    guard let version = try? String(contentsOf: AppConstants.installomatorVersionFileURL, encoding: .utf8) else {
        return "unknown"
    }
    return version.trimmingCharacters(in: .whitespacesAndNewlines)
}

func loadManagedLabelsVersion() -> String {
    guard let version = try? String(contentsOf: AppConstants.managedLabelsVersionFileURL, encoding: .utf8) else {
        return ""
    }
    return version.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Returns a combined version string covering both Installomator and managed labels.
/// When either version changes, broken labels are rechecked.
func loadEffectiveLabelsVersion() -> String {
    let installomator = Preferences().installomatorLabelsDisable ? "" : loadInstallomatorVersion()
    let managed       = loadManagedLabelsVersion()
    switch (installomator.isEmpty, managed.isEmpty) {
    case (false, false): return "\(installomator)+managed:\(managed)"
    case (false, true):  return installomator
    case (true,  false): return "managed:\(managed)"
    case (true,  true):  return ""
    }
}


func loadPreviousBrokenState() -> (labels: [String], installomatorVersion: String) {
    guard let data = try? Data(contentsOf: AppConstants.patcherConfigFileURL),
          let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return ([], "")
    }
    let labels = config["lastScanBrokenLabels"] as? [String] ?? []
    let version = config["lastScanFullInstallomatorVersion"] as? String ?? ""
    return (labels, version)
}


func loadStageBrokenState() -> (labels: [String], installomatorVersion: String, failedAttempts: [String: Int]) {
    guard let data = try? Data(contentsOf: AppConstants.patcherConfigFileURL),
          let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return ([], "", [:])
    }
    let labels = config["stageBrokenLabels"] as? [String] ?? []
    let version = config["stageInstallomatorVersion"] as? String ?? ""
    let failedAttempts = config["stageFailedAttempts"] as? [String: Int] ?? [:]
    return (labels, version, failedAttempts)
}

func loadApplyBrokenState() -> (failedAttempts: [String: Int], brokenVersions: [String: String]) {
    guard let data = try? Data(contentsOf: AppConstants.patcherConfigFileURL),
          let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return ([:], [:])
    }
    let failedAttempts = config["applyFailedAttempts"] as? [String: Int] ?? [:]
    let brokenVersions = config["applyBrokenVersions"] as? [String: String] ?? [:]
    return (failedAttempts, brokenVersions)
}


func updateConfigJSON(_ updates: [String: Any]) {
    let configURL = AppConstants.patcherConfigFileURL
    var config: [String: Any] = [:]

    // Load existing config if present
    if let data = try? Data(contentsOf: configURL),
       let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        config = existing
    }

    for (key, value) in updates {
        config[key] = value
    }

    do {
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configURL, options: .atomic)
        Logger.log("💾 Updated config.json")
    } catch {
        Logger.log("❌ Failed to write config.json: \(error)")
    }
}


func removeDiscoveredPlistIfPresent(label: String) {
    let plistURL = AppConstants.patcherDiscoveredFolderURL.appendingPathComponent("\(label).plist")
    guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
    do {
        try FileManager.default.removeItem(at: plistURL)
        Logger.log("🗑️ Removed discovered plist for ignored label: \(label)")
    } catch {
        Logger.log("❌ Failed to remove discovered plist for \(label): \(error)")
    }
}


func writeDiscoveredPlist(label: String, jsonDict: [String: Any], installedVersion: String, updateStatus: UpdateStatus, foundInstalls: [FoundInstall]? = nil) {
    var plistDict = jsonDict
    plistDict["installedVersion"] = installedVersion
    plistDict["updateStatus"] = updateStatus.rawValue

    if let foundInstalls {
        plistDict["foundInstalls"] = foundInstalls.map { ["path": $0.path, "version": $0.version, "discoveryMethod": $0.discoveryMethod] }
    }

    let plistURL = AppConstants.patcherDiscoveredFolderURL.appendingPathComponent("\(label).plist")

    do {
        let data = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        Logger.log("💾 Wrote discovered plist: \(plistURL.lastPathComponent)")
    } catch {
        Logger.log("❌ Failed to write discovered plist for \(label): \(error)")
    }
    recordDiscoveredIfNeeded(label: label, installedVersion: installedVersion, date: Date())
}


func getApplicationVersion(appWithExtension: String, versionKey: String? = "CFBundleShortVersionString", targetDir: String? = nil) -> [FoundInstall]? {
    let fileManager = FileManager.default
    let keyToCheck = versionKey?.isEmpty == false ? versionKey! : "CFBundleShortVersionString"

    // Build paths to check: targetDir first (if provided), then standard locations as fallback
    var appPaths = [
        "/Applications/\(appWithExtension)",
        "/Applications/Utilities/\(appWithExtension)"
    ]
    if let targetDir, !targetDir.isEmpty {
        let dir = targetDir.hasSuffix("/") ? String(targetDir.dropLast()) : targetDir
        appPaths.insert("\(dir)/\(appWithExtension)", at: 0)
    }

    var found: [FoundInstall] = []

    for appPath in appPaths {
        guard fileManager.fileExists(atPath: appPath) else { continue }

        if fileManager.fileExists(atPath: "\(appPath)/Contents/_MASReceipt") {
            Logger.log("🛍️ \(appWithExtension) at \(appPath) is an App Store install — skipping")
            continue
        }

        Logger.log("✅ Found \(appWithExtension) at \(appPath)")

        let infoPlistPath = "\(appPath)/Contents/Info.plist"
        if let plistData = NSDictionary(contentsOfFile: infoPlistPath),
           let version = plistData[keyToCheck] as? String {
            Logger.log("📦 \(appWithExtension) Version: \(version) (Key: \(keyToCheck))")
            found.append(FoundInstall(path: appPath, version: version, discoveryMethod: "path"))
        } else {
            Logger.log("⚠️ Failed to retrieve version info for \(appWithExtension) at \(appPath)")
        }
    }

    // Supplement with mdfind to catch installs outside the checked paths
    let foundPaths = Set(found.map { $0.path })
    for appPath in runMdfind(appWithExtension: appWithExtension) {
        guard !foundPaths.contains(appPath) else { continue }

        if fileManager.fileExists(atPath: "\(appPath)/Contents/_MASReceipt") {
            Logger.log("🛍️ \(appWithExtension) at \(appPath) is an App Store install — skipping")
            continue
        }

        Logger.log("✅ Found \(appWithExtension) via mdfind at \(appPath)")

        let infoPlistPath = "\(appPath)/Contents/Info.plist"
        if let plistData = NSDictionary(contentsOfFile: infoPlistPath),
           let version = plistData[keyToCheck] as? String {
            Logger.log("📦 \(appWithExtension) Version: \(version) via mdfind")
            found.append(FoundInstall(path: appPath, version: version, discoveryMethod: "mdfind"))
        } else {
            Logger.log("⚠️ Failed to retrieve version info for \(appWithExtension) at \(appPath)")
        }
    }

    if found.isEmpty {
        Logger.log("❌ Application \(appWithExtension) not found via paths or mdfind")
        return nil
    }

    return found
}

private func runMdfind(appWithExtension: String) -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
    process.arguments = ["kMDItemContentType == 'com.apple.application-bundle' && kMDItemFSName == '\(appWithExtension)'", "-0"]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        Logger.log("❌ mdfind failed for \(appWithExtension): \(error)")
        return []
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return [] }
    return output.components(separatedBy: "\0").filter { path in
        guard !path.isEmpty else { return false }
        return !path.hasPrefix("/Library/") && !path.hasPrefix("/System/")
    }
}


func getPackageVersion(packageID: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
    process.arguments = ["--pkg-info-plist", packageID]

    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = Pipe()

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        Logger.log("❌ Failed to run pkgutil for \(packageID): \(error)")
        return nil
    }

    guard process.terminationStatus == 0 else {
        Logger.log("❌ Package \(packageID) not installed (pkgutil exit \(process.terminationStatus))")
        return nil
    }

    // Package IS installed — read version from receipt.
    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()

    do {
        if let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let version = plist["pkg-version"] as? String,
           !version.isEmpty,
           !version.split(separator: ".").allSatisfy({ $0 == "0" }) {
            Logger.log("📦 Package \(packageID) installed version: \(version)")
            return version
        }
    } catch {
        Logger.log("❌ Failed to parse pkgutil output for \(packageID): \(error)")
    }

    Logger.log("⚠️ Package \(packageID) version could not be determined from receipt")
    return nil
}


func appendToCSV(_ row: String) {
    if let data = row.data(using: .utf8) {
        if let fileHandle = try? FileHandle(forWritingTo: AppConstants.csvFilePath) {
            defer { fileHandle.closeFile() }
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
        } else {
            Logger.log("⚠️ Could not open file for writing: \(AppConstants.csvFilePath.path)")
        }
    }
}

func getEnvironmentVars() -> [String: String] {
    var systemInfo: [String: String] = [
        "computername": Host.current().localizedName ?? "Mac",
        "computermodel": marketingModel,
        "serialnumber": deviceSerialNumber,
        "username": consoleUserInfo.username,
        "user ID": consoleUserInfo.userID,
        "userfullname": NSFullUserName(),
        "osversion": ProcessInfo.processInfo.osVersionString,
        "osname": ProcessInfo.processInfo.osName
    ]

    let env = ProcessInfo.processInfo.environment
    for (key, value) in env {
        systemInfo[key] = value
    }
    return systemInfo
}


// MARK: - Apply Updates

/// Returns the number of days since the oldest staged update in the cache.
/// Reads `stagedTimestamp` from each label's metadata.json and returns the
/// age of the earliest one in whole days, or 0 if no staged timestamps are found.
/// Returns true if any label cache directory contains a staged install file
/// (any file other than metadata.json and history.json).
func hasStagedUpdates() -> Bool {
    let cacheURL = AppConstants.patcherCacheFolderURL
    guard let labelDirs = try? FileManager.default.contentsOfDirectory(
        at: cacheURL, includingPropertiesForKeys: [.isDirectoryKey]
    ) else { return false }

    for labelDir in labelDirs {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: labelDir.path, isDirectory: &isDir),
              isDir.boolValue else { continue }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: labelDir, includingPropertiesForKeys: nil
        )) ?? []
        if contents.contains(where: {
            $0.lastPathComponent != "metadata.json" && $0.lastPathComponent != "history.json"
        }) { return true }
    }
    return false
}

func daysSinceOldestStagedUpdate() -> Int {
    let cacheURL = AppConstants.patcherCacheFolderURL
    let iso = ISO8601DateFormatter()
    let now = Date()
    var oldest: Date? = nil

    guard let labelDirs = try? FileManager.default.contentsOfDirectory(
        at: cacheURL, includingPropertiesForKeys: [.isDirectoryKey]
    ) else { return 0 }

    for labelDir in labelDirs {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: labelDir.path, isDirectory: &isDir),
              isDir.boolValue else { continue }

        let metadataURL = labelDir.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tsString = json["stagedTimestamp"] as? String,
              let ts = iso.date(from: tsString) else { continue }

        if oldest == nil || ts < oldest! { oldest = ts }
    }

    guard let first = oldest else { return 0 }
    return max(0, Calendar.current.dateComponents([.day], from: first, to: now).day ?? 0)
}

/// Returns the number of days since the monthly patch day this month.
/// Day 0 = the target date itself; +1 for each subsequent day.
/// Returns 0 if the target date has not yet arrived this month.
func daysSinceMonthlyPatchDay(prefs: Preferences, now: Date = Date()) -> Int {
    var cal = Calendar.current
    cal.locale = Locale(identifier: "en_US_POSIX")
    var comps = cal.dateComponents([.year, .month], from: now)
    comps.weekday        = prefs.patchingWeekday
    comps.weekdayOrdinal = prefs.patchingWeekOfMonth
    guard let targetDate = cal.date(from: comps), targetDate <= now else { return 0 }
    return max(0, cal.dateComponents([.day], from: targetDate, to: now).day ?? 0)
}

func applyUpdates(labelFilter: String? = nil, suppressDialog: Bool = false, daysPending: Int = 0) {
    let applyStart = Date()
    let iso = ISO8601DateFormatter()
    Logger.log("🔧 Apply started at \(iso.string(from: applyStart))")

    let prefs = Preferences()

    let applyBrokenState = loadApplyBrokenState()
    var applyFailedAttempts = applyBrokenState.failedAttempts
    var applyBrokenVersions = applyBrokenState.brokenVersions
    let applyFailThreshold  = prefs.applyFailThreshold

    // In monthly patching mode, daysPending counts from the patch day this month
    // (day 0 on the target date, +1 each subsequent day) rather than from when
    // updates were staged, since all patches are intentionally released together.
    // In deadline mode, use the age of the oldest staged update.
    let effectiveDaysPending: Int
    if prefs.monthlyPatchingCadenceEnabled {
        effectiveDaysPending = daysSinceMonthlyPatchDay(prefs: prefs)
        Logger.log("ℹ️ Days pending (monthly patch cycle): \(effectiveDaysPending)")
    } else {
        effectiveDaysPending = daysSinceOldestStagedUpdate()
        Logger.log("ℹ️ Days pending (oldest staged update): \(effectiveDaysPending)")
    }
    let ignoreAppsInHomeFolder = prefs.ignoreAppsInHomeFolder
    // ConvertAppsInHomeFolder is fully ignored when IgnoreAppsInHomeFolder is true
    let effectiveConvert = prefs.convertAppsInHomeFolder && !ignoreAppsInHomeFolder
    let blockingAction = BlockingProcessAction(rawValue: prefs.blockingProcessAction)
    let countdownSeconds = prefs.blockingProcessCountdownSeconds

    let cacheBaseURL = AppConstants.patcherCacheFolderURL
    let fileManager = FileManager.default

    // Declared before do/catch so it's accessible in the catch block for cleanup.
    var dialog: SwiftDialogController? = nil

    do {
        var labelDirs = try fileManager.contentsOfDirectory(at: cacheBaseURL, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let labelFilter {
            labelDirs = labelDirs.filter { $0.lastPathComponent == labelFilter }
        }

        // ── Pre-scan: build the dialog item list before starting installs ──────────
        // swiftDialog needs the full list at launch time.
        var dialogItems: [SwiftDialogController.ApplyItem] = []
        for dirURL in labelDirs {
            guard findStagedFile(in: dirURL) != nil else { continue }
            let lbl = dirURL.lastPathComponent
            let plistURL = AppConstants.patcherDiscoveredFolderURL.appendingPathComponent("\(lbl).plist")

            var displayName = lbl
            var iconPath: String? = nil

            if let data = try? Data(contentsOf: plistURL),
               let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                if let n = plist["name"] as? String, !n.isEmpty {
                    displayName = n
                }
                // Use the first existing .app bundle path as the icon source.
                // swiftDialog's JSON listitem format accepts .app bundle paths directly.
                if let installs = plist["foundInstalls"] as? [[String: Any]] {
                    for install in installs {
                        if let appPath = install["path"] as? String,
                           appPath.hasSuffix(".app"),
                           fileManager.fileExists(atPath: appPath) {
                            iconPath = appPath
                            break
                        }
                    }
                }
            }
            dialogItems.append(SwiftDialogController.ApplyItem(label: lbl, displayName: displayName, iconPath: iconPath))
        }

        // ── Deferral gate + progress dialog ────────────────────────────────────
        if !suppressDialog, !dialogItems.isEmpty, let controller = SwiftDialogController.makeIfAvailable() {

            // Check for an unexpired deferral recorded in a previous run.
            var deferralState = DeferralState.load()
//            if deferralState.isActive() {
//                let remaining = deferralState.remainingMinutes()
//                Logger.log("⏸️ Apply: active deferral — \(formatDeferralDuration(remaining)) remaining. Exiting.")
//                return
//            }

            // Show the pre-install deferral prompt.
            let hardDeadline = prefs.deadlineDaysHard > 0 && effectiveDaysPending >= prefs.deadlineDaysHard
            let promptResult = controller.showDeferralPrompt(
                itemCount:           dialogItems.count,
                daysPending:         effectiveDaysPending,
                hardDeadlineReached: hardDeadline,
                prefs:               prefs
            )

            let pendingLabels = dialogItems.map(\.label)
            switch promptResult {
            case .deferred(let minutes):
                recordDeferralOutcome(labels: pendingLabels, result: promptResult, date: Date())
                deferralState.recordDeferral(minutes: minutes)
                deferralState.save()
                Logger.log("⏸️ Apply deferred for \(formatDeferralDuration(minutes)) (deferral #\(deferralState.count)). Exiting.")
                return
            case .timedOutDeferred(let minutes):
                recordDeferralOutcome(labels: pendingLabels, result: promptResult, date: Date())
                deferralState.recordDeferral(minutes: minutes)
                deferralState.save()
                Logger.log("⏸️ Apply auto-deferred (timer) for \(formatDeferralDuration(minutes)) (deferral #\(deferralState.count)). Exiting.")
                return
            case .deadlineForced:
                recordDeferralOutcome(labels: pendingLabels, result: promptResult, date: Date())
                Logger.log("▶️ Apply: hard deadline reached — proceeding")
            case .proceed:
                recordDeferralOutcome(labels: pendingLabels, result: promptResult, date: Date())
                Logger.log("▶️ Apply: user chose to continue")
            }

            dialog = controller
        }
        dialog?.launchProgressDialog(items: dialogItems)

        var appliedCount = 0
        var nothingToInstallCount = 0
        var skippedCount = 0
        var failedCount = 0
        var currentItemIndex = 0
        var blockedSkipOccurred = false

        for labelDirURL in labelDirs {
            let label = labelDirURL.lastPathComponent

            // Stop before starting a new installation if shutdown was requested.
            // Any installation already in progress ran to completion — this is
            // the only safe point to honour a SIGTERM without risking a half-applied pkg.
            if shutdownRequested {
                Logger.log("⚠️ Shutdown requested — stopping apply before '\(label)'. Already applied: \(appliedCount).")
                dialog?.setProgressText("Shutdown — stopping after \(appliedCount) item\(appliedCount == 1 ? "" : "s")")
                break
            }

            Logger.log("--------------------------------------------------")

            // A cache dir with only metadata.json (or empty) means nothing is staged
            guard let stagedFileURL = findStagedFile(in: labelDirURL) else {
                Logger.log("📭 \(label) — nothing staged to install")
                nothingToInstallCount += 1
                continue
            }

            currentItemIndex += 1
            let dialogItem = dialogItems.first(where: { $0.label == label })
                ?? SwiftDialogController.ApplyItem(label: label, displayName: label)

            // Read the discovered plist for install metadata
            let plistURL = AppConstants.patcherDiscoveredFolderURL.appendingPathComponent("\(label).plist")
            guard let plistData = try? Data(contentsOf: plistURL),
                  let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
                Logger.log("⚠️ \(label) — could not read discovered plist, skipping")
                dialog?.setSkipped(item: dialogItem, reason: "No plist")
                skippedCount += 1
                continue
            }

            guard let type = plist["type"] as? String, !type.isEmpty else {
                Logger.log("⚠️ \(label) — missing type in discovered plist, skipping")
                dialog?.setSkipped(item: dialogItem, reason: "No type")
                skippedCount += 1
                continue
            }

            let appNewVersion         = plist["appNewVersion"] as? String ?? ""
            let priorInstalledVersion = plist["installedVersion"] as? String ?? ""
            let appName               = plist["appName"] as? String
            let name                  = plist["name"] as? String
            let foundInstalls         = plist["foundInstalls"] as? [[String: Any]] ?? []

            // Determine blocking processes:
            //   ["NONE"]  → nothing blocks
            //   []        → the label's "name" value is the blocker
            //   [...]     → the listed process names are blockers
            let rawBlockers = plist["blockingProcesses"] as? [String] ?? []
            let effectiveBlockers: [String]
            if rawBlockers == ["NONE"] {
                effectiveBlockers = []
            } else if rawBlockers.isEmpty {
                effectiveBlockers = name.map { [$0] } ?? []
            } else {
                effectiveBlockers = rawBlockers
            }

            if blockingAction != .ignore,
               let runningBlocker = effectiveBlockers.first(where: { isProcessRunning($0) }) {
                Logger.log("⏸️ \(label) — '\(runningBlocker)' is running (action: \(prefs.blockingProcessAction))")
                let response = dialog?.handleBlockingProcess(
                    processName:      runningBlocker,
                    item:             dialogItem,
                    action:           blockingAction,
                    countdownSeconds: countdownSeconds
                ) ?? {
                    // No dialog: apply the action silently
                    switch blockingAction {
                    case .kill:
                        let p = Process()
                        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                        p.arguments = ["-x", runningBlocker]
                        try? p.run(); p.waitUntilExit()
                        Thread.sleep(forTimeInterval: 2.0)
                        return BlockingActionResponse.proceed
                    default:
                        return BlockingActionResponse.skip
                    }
                }()

                if response == .skip {
                    dialog?.setSkipped(item: dialogItem, reason: "App running")
                    skippedCount += 1
                    blockedSkipOccurred = true
                    continue
                }
                // .proceed falls through to install below
            }

            dialog?.setInProgress(item: dialogItem, current: currentItemIndex, total: dialogItems.count)
            Logger.log("📦 Installing: \(label) v\(appNewVersion) (\(type))")
            Logger.log("   File: \(stagedFileURL.lastPathComponent)")

            let success: Bool

            switch type {
            case "pkg":
                success = runInstaller(pkgPath: stagedFileURL.path, label: label)

            case "pkgInZip":
                let tempDir = AppConstants.patcherTempFolderURL.appendingPathComponent("install-\(UUID().uuidString)").path
                do { try fileManager.createDirectory(atPath: tempDir, withIntermediateDirectories: true) } catch {}
                defer { try? fileManager.removeItem(atPath: tempDir) }
                success = unzipped(filePath: stagedFileURL.path, to: tempDir) {
                    guard let pkgPath = findItem(ext: "pkg", in: tempDir) else {
                        Logger.log("⚠️ No .pkg found in ZIP for \(label)")
                        return false
                    }
                    return runInstaller(pkgPath: pkgPath, label: label)
                } ?? false

            case "pkgInDmgInZip":
                let tempDir = AppConstants.patcherTempFolderURL.appendingPathComponent("install-\(UUID().uuidString)").path
                do { try fileManager.createDirectory(atPath: tempDir, withIntermediateDirectories: true) } catch {}
                defer { try? fileManager.removeItem(atPath: tempDir) }
                success = unzipped(filePath: stagedFileURL.path, to: tempDir) {
                    guard let dmgPath = findItem(ext: "dmg", in: tempDir) else {
                        Logger.log("⚠️ No .dmg found in ZIP for \(label)")
                        return false
                    }
                    return withMountedDMG(at: dmgPath) { mountPoint in
                        guard let pkgPath = findItem(ext: "pkg", in: mountPoint) else {
                            Logger.log("⚠️ No .pkg found in DMG (inside ZIP) for \(label)")
                            return false
                        }
                        return runInstaller(pkgPath: pkgPath, label: label)
                    } ?? false
                } ?? false

            case "pkgInDmg":
                success = withMountedDMG(at: stagedFileURL.path) { mountPoint in
                    guard let pkgPath = findItem(ext: "pkg", in: mountPoint) else {
                        Logger.log("⚠️ No .pkg found in DMG for \(label)")
                        return false
                    }
                    return runInstaller(pkgPath: pkgPath, label: label)
                } ?? false

            default:
                // App-based types: dmg, zip, tbz, appInDmgInZip
                let cliInstaller  = plist["CLIInstaller"]  as? String
                let installerTool = plist["installerTool"] as? String
                let cliArguments  = plist["CLIArguments"]  as? String
                let useCLI = !(cliInstaller?.isEmpty ?? true)

                let targets: [String]
                let toDelete: [String]

                if useCLI {
                    // foundInstalls is ignored — the CLI tool handles installation entirely
                    Logger.log("   CLI installer: \(cliInstaller!)")
                    targets  = []
                    toDelete = []
                } else {
                    (targets, toDelete) = resolveInstallTargets(
                        foundInstalls: foundInstalls,
                        appName: appName,
                        name: name,
                        label: label,
                        ignoreAppsInHomeFolder: ignoreAppsInHomeFolder,
                        effectiveConvert: effectiveConvert
                    )
                    guard !targets.isEmpty else {
                        Logger.log("⏭️ \(label) — no install targets after applying preferences")
                        skippedCount += 1
                        continue
                    }
                }

                success = installAppFromStagedFile(
                    stagedFilePath: stagedFileURL.path,
                    type: type,
                    appName: appName,
                    name: name,
                    targets: targets,
                    toDelete: toDelete,
                    cliInstaller: cliInstaller,
                    installerTool: installerTool,
                    cliArguments: cliArguments,
                    label: label
                )
            }

            if success {
                updateDiscoveredPlist(label: label, updates: [
                    "installedVersion": appNewVersion,
                    "updateStatus": UpdateStatus.upToDate.rawValue
                ])
                try? fileManager.removeItem(at: stagedFileURL)
                appendCacheInstallTimestamp(label: label, timestamp: iso.string(from: Date()), labelCacheURL: labelDirURL)
                recordApplied(label: label, fromVersion: priorInstalledVersion, toVersion: appNewVersion, date: Date())
                dialog?.setSuccess(item: dialogItem, toVersion: appNewVersion)
                Logger.log("✅ Successfully installed \(label)")
                appliedCount += 1
                applyFailedAttempts.removeValue(forKey: label)
                applyBrokenVersions.removeValue(forKey: label)
            } else {
                dialog?.setFailed(item: dialogItem)
                Logger.log("❌ Failed to install \(label)")
                failedCount += 1
                let attempts = (applyFailedAttempts[label] ?? 0) + 1
                applyFailedAttempts[label] = attempts
                Logger.log("   Apply failure count for \(label): \(attempts)/\(applyFailThreshold)")
                if attempts >= applyFailThreshold {
                    Logger.log("🚫 \(label) reached apply failure threshold — staged file deleted, v\(appNewVersion) will not be re-staged")
                    try? fileManager.removeItem(at: stagedFileURL)
                    applyBrokenVersions[label] = appNewVersion
                    applyFailedAttempts.removeValue(forKey: label)
                }
            }
        }

        let applyEnd = Date()
        let duration = applyEnd.timeIntervalSince(applyStart)
        Logger.log("--------------------------------------------------")
        Logger.log("✅ Apply complete — \(appliedCount) installed, \(nothingToInstallCount) nothing-to-install, \(skippedCount) skipped, \(failedCount) failed, \(String(format: "%.2f", duration))s")

        dialog?.complete(applied: appliedCount, skipped: skippedCount, failed: failedCount)
        // Wait for the user to click Done (or for the auto-dismiss timer to fire).
        // waitForDialog() returns as soon as swiftDialog exits, so clicking Done
        // is immediate — no fixed sleep delay.
        dialog?.waitForDialog()

        // If any label was skipped due to a blocking process, count that as a deferral.
        // This keeps the deadline counter accurate even when the user didn't see the prompt.
        if blockedSkipOccurred {
            var deferralState = DeferralState.load()
            deferralState.count += 1
            deferralState.save()
            Logger.log("ℹ️ Blocking-process skip recorded as deferral #\(deferralState.count).")
        }

        // Reset deferral only when all staged updates have been applied.
        // If some were skipped (blocking process still running), keep the
        // deferral count so the deadline logic remains accurate.
        if !hasStagedUpdates() {
            var deferralState = DeferralState.load()
            deferralState.reset()
            deferralState.save()
            Logger.log("ℹ️ All staged updates applied — deferral state reset.")
        } else {
            Logger.log("ℹ️ Some staged updates remain — deferral state preserved.")
        }

        // When suppressDialog or no dialog items were staged, skip config update
        // for single-label ensure runs so they don't corrupt fleet-wide stats.
        if labelFilter == nil {
            updateConfigJSON([
                "lastApplyStart": iso.string(from: applyStart),
                "lastApplyEnd": iso.string(from: applyEnd),
                "lastApplyDurationSeconds": duration,
                "lastApplyCount": appliedCount,
                "lastApplyNothingToInstallCount": nothingToInstallCount,
                "lastApplySkippedCount": skippedCount,
                "lastApplyFailedCount": failedCount,
                "applyFailedAttempts": applyFailedAttempts,
                "applyBrokenVersions": applyBrokenVersions
            ])
        }

    } catch {
        dialog?.dismiss()
        Logger.log("❌ Error during apply: \(error)")
    }
}


/// Returns the version string as-is if it looks like a real version, or "" if it looks like
/// HTML garbage or other scraping noise. Two rules are applied:
///   1. Length > 40 characters → rejected (all known real version strings fit well within this)
///   2. Any character outside [0-9 A-Z a-z . - _ + :] → rejected (catches HTML entities, spaces, tags)
private func sanitizedVersion(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    guard trimmed.count <= 40 else { return "" }
    let allowed = CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._-+:")
    guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return "" }
    return trimmed
}


/// Returns true if a process with the given name is currently running.
/// Uses `pgrep -x` for an exact-name match.
private func isProcessRunning(_ processName: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-x", processName]
    process.standardOutput = FileHandle.nullDevice
    process.standardError  = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}


/// Returns the staged install file from a label's cache directory — the first file that is not metadata.json.
/// Returns nil if only metadata.json is present or the directory is empty.
private func findStagedFile(in labelCacheURL: URL) -> URL? {
    guard let contents = try? FileManager.default.contentsOfDirectory(at: labelCacheURL, includingPropertiesForKeys: nil) else { return nil }
    return contents.first(where: { $0.lastPathComponent != "metadata.json" && $0.lastPathComponent != LabelHistory.fileName })
}


/// Resolves the set of install target paths for an app-based label, applying home-folder preferences.
/// Returns the paths to install to and any /Users/ paths to delete first (for the convert case).
private func resolveInstallTargets(
    foundInstalls: [[String: Any]],
    appName: String?,
    name: String?,
    label: String,
    ignoreAppsInHomeFolder: Bool,
    effectiveConvert: Bool
) -> (targets: [String], toDelete: [String]) {
    // No prior installs recorded — default to /Applications/<appBundleName>
    if foundInstalls.isEmpty {
        let bundleName: String
        if let appName, !appName.isEmpty {
            bundleName = appName.hasSuffix(".app") ? appName : "\(appName).app"
        } else if let name, !name.isEmpty {
            bundleName = "\(name).app"
        } else {
            bundleName = "\(label).app"
        }
        Logger.log("ℹ️ No foundInstalls for \(label) — defaulting to /Applications/\(bundleName)")
        return (["/Applications/\(bundleName)"], [])
    }

    var targetSet = Set<String>()
    var toDelete:  [String] = []

    for install in foundInstalls {
        guard let path = install["path"] as? String else { continue }
        if path.hasPrefix("/Users/") {
            if ignoreAppsInHomeFolder {
                Logger.log("⏭️ Skipping /Users/ path: \(path) (IgnoreAppsInHomeFolder)")
            } else if effectiveConvert {
                toDelete.append(path)
                let bundleName = (path as NSString).lastPathComponent
                let dest = "/Applications/\(bundleName)"
                if targetSet.insert(dest).inserted {
                    Logger.log("🔄 Will convert: \(path) → \(dest)")
                }
            } else {
                targetSet.insert(path)
            }
        } else {
            targetSet.insert(path)
        }
    }
    return (targets: Array(targetSet).sorted(), toDelete: toDelete)
}


/// Mounts/extracts the staged file by type, then either runs a CLI installer or copies the .app to each target.
private func installAppFromStagedFile(
    stagedFilePath: String,
    type: String,
    appName: String?,
    name: String?,
    targets: [String],
    toDelete: [String],
    cliInstaller: String?,
    installerTool: String?,
    cliArguments: String?,
    label: String
) -> Bool {
    // Delete /Users/ originals first (convert case; no-op when CLI installer is used)
    for path in toDelete {
        do {
            try FileManager.default.removeItem(atPath: path)
            Logger.log("🗑️ Removed: \(path)")
        } catch {
            Logger.log("⚠️ Could not remove \(path): \(error)")
        }
    }

    let useCLI = !(cliInstaller?.isEmpty ?? true)

    switch type {
    case "dmg":
        return withMountedDMG(at: stagedFilePath) { mountPoint in
            if useCLI {
                return runCLIInstaller(cliInstaller: cliInstaller!, installerTool: installerTool, cliArguments: cliArguments, in: mountPoint, label: label)
            }
            return findAndInstallApp(in: mountPoint, appName: appName, name: name, targets: targets, label: label)
        } ?? false

    case "zip":
        let tempDir = AppConstants.patcherTempFolderURL.appendingPathComponent("install-\(UUID().uuidString)").path
        do { try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true) } catch {}
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        return unzipped(filePath: stagedFilePath, to: tempDir) {
            if useCLI {
                return runCLIInstaller(cliInstaller: cliInstaller!, installerTool: installerTool, cliArguments: cliArguments, in: tempDir, label: label)
            }
            return findAndInstallApp(in: tempDir, appName: appName, name: name, targets: targets, label: label)
        } ?? false

    case "tbz":
        let tempDir = AppConstants.patcherTempFolderURL.appendingPathComponent("install-\(UUID().uuidString)").path
        do { try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true) } catch {}
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        return untarred(filePath: stagedFilePath, to: tempDir) {
            if useCLI {
                return runCLIInstaller(cliInstaller: cliInstaller!, installerTool: installerTool, cliArguments: cliArguments, in: tempDir, label: label)
            }
            return findAndInstallApp(in: tempDir, appName: appName, name: name, targets: targets, label: label)
        } ?? false

    case "appInDmgInZip":
        let tempDir = AppConstants.patcherTempFolderURL.appendingPathComponent("install-\(UUID().uuidString)").path
        do { try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true) } catch {}
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        return unzipped(filePath: stagedFilePath, to: tempDir) {
            guard let dmgPath = findItem(ext: "dmg", in: tempDir) else {
                Logger.log("⚠️ No .dmg found in ZIP for \(label)")
                return false
            }
            return withMountedDMG(at: dmgPath) { mountPoint in
                if useCLI {
                    return runCLIInstaller(cliInstaller: cliInstaller!, installerTool: installerTool, cliArguments: cliArguments, in: mountPoint, label: label)
                }
                return findAndInstallApp(in: mountPoint, appName: appName, name: name, targets: targets, label: label)
            } ?? false
        } ?? false

    default:
        Logger.log("⚠️ Unsupported app type '\(type)' for installation")
        return false
    }
}


/// Finds the .app bundle in a directory and installs it to each target path.
private func findAndInstallApp(in directory: String, appName: String?, name: String?, targets: [String], label: String) -> Bool {
    let appPath: String?
    if let appName, !appName.isEmpty {
        let target = appName.hasSuffix(".app") ? appName : "\(appName).app"
        appPath = findItemNamed(target, in: directory) ?? findItem(ext: "app", in: directory)
    } else if let name, !name.isEmpty {
        appPath = findItemNamed("\(name).app", in: directory) ?? findItem(ext: "app", in: directory)
    } else {
        appPath = findItem(ext: "app", in: directory)
    }

    guard let sourceApp = appPath else {
        Logger.log("⚠️ No .app found in \(directory) for \(label)")
        return false
    }
    Logger.log("   Source: \(sourceApp)")

    var allSucceeded = true
    for target in targets {
        if copyApp(from: sourceApp, to: target, label: label) {
            Logger.log("✅ Installed to: \(target)")
        } else {
            Logger.log("❌ Failed to install to: \(target)")
            allSucceeded = false
        }
    }
    return allSucceeded
}


/// Resolves the full path to the CLI installer executable within a mounted/extracted container.
/// Uses `installerTool` as the search anchor if provided, otherwise uses the first path component
/// of `cliInstaller`. The returned path is: parent-of-found-anchor + "/" + cliInstaller.
private func resolveCLIInstallerPath(cliInstaller: String, installerTool: String?, in directory: String) -> String? {
    let searchTarget: String
    if let tool = installerTool, !tool.isEmpty {
        searchTarget = tool
    } else {
        // Derive anchor from first component of the CLIInstaller path ("Install.app/Contents/..." → "Install.app")
        searchTarget = (cliInstaller as NSString).pathComponents.first ?? cliInstaller
    }

    guard let foundTool = findItemNamed(searchTarget, in: directory) else {
        Logger.log("⚠️ Could not find '\(searchTarget)' in container for CLI installer")
        return nil
    }

    // The CLIInstaller path is relative from the same parent directory that contains the anchor
    let baseDir = (foundTool as NSString).deletingLastPathComponent
    return (baseDir as NSString).appendingPathComponent(cliInstaller)
}


/// Finds the CLI installer executable inside a container directory and runs it with the given arguments.
private func runCLIInstaller(cliInstaller: String, installerTool: String?, cliArguments: String?, in directory: String, label: String) -> Bool {
    guard let executablePath = resolveCLIInstallerPath(cliInstaller: cliInstaller, installerTool: installerTool, in: directory) else {
        Logger.log("❌ Could not resolve CLI installer path for \(label)")
        return false
    }

    guard FileManager.default.fileExists(atPath: executablePath) else {
        Logger.log("❌ CLI installer not found at resolved path: \(executablePath)")
        return false
    }

    Logger.log("   Executable: \(executablePath)")

    let args = cliArguments.map { shellSplit($0) } ?? []
    if !args.isEmpty {
        Logger.log("   Arguments: \(args.joined(separator: " "))")
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        Logger.log("❌ CLI installer launch error for \(label): \(error)")
        return false
    }

    let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Logger.log("   Output: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    guard process.terminationStatus == 0 else {
        let errMsg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        Logger.log("❌ CLI installer failed (exit \(process.terminationStatus)) for \(label): \(errMsg.trimmingCharacters(in: .whitespacesAndNewlines))")
        return false
    }
    return true
}


/// Removes the existing app at the target path and copies the new one using ditto.
private func copyApp(from sourceApp: String, to targetPath: String, label: String) -> Bool {
    let fileManager = FileManager.default
    let parentDir = (targetPath as NSString).deletingLastPathComponent

    do { try fileManager.createDirectory(atPath: parentDir, withIntermediateDirectories: true) } catch {}

    if fileManager.fileExists(atPath: targetPath) {
        do {
            try fileManager.removeItem(atPath: targetPath)
        } catch {
            Logger.log("❌ Could not remove existing app at \(targetPath): \(error)")
            return false
        }
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = [sourceApp, targetPath]
    process.standardOutput = Pipe()
    let errPipe = Pipe()
    process.standardError = errPipe
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        Logger.log("❌ ditto launch error for \(label): \(error)")
        return false
    }
    guard process.terminationStatus == 0 else {
        let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        Logger.log("❌ ditto failed for \(label): \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        return false
    }
    return fileManager.fileExists(atPath: targetPath)
}


/// Runs /usr/sbin/installer to install a .pkg to the root volume.
private func runInstaller(pkgPath: String, label: String) -> Bool {
    Logger.log("📦 Running installer for \(label)...")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/installer")
    process.arguments = ["-pkg", pkgPath, "-target", "/"]
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        Logger.log("❌ installer launch error for \(label): \(error)")
        return false
    }
    let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Logger.log("   installer: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    guard process.terminationStatus == 0 else {
        let errMsg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        Logger.log("❌ installer failed (exit \(process.terminationStatus)): \(errMsg.trimmingCharacters(in: .whitespacesAndNewlines))")
        return false
    }
    return true
}


/// Writes the post-install metadata.json, recording installedTimestamp and preserving any
/// unknownVersionCheckCount. Removes the staged-file keys (appNewVersion, downloadURL,
/// stagedTimestamp) so the stage deduplication check does not falsely match on the next run.
private func appendCacheInstallTimestamp(label: String, timestamp: String, labelCacheURL: URL) {
    let metadataURL = labelCacheURL.appendingPathComponent("metadata.json")
    var metadata: [String: Any] = [:]
    if let data = try? Data(contentsOf: metadataURL),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        metadata = json
    }
    // Strip staged-file fields — they're no longer valid once the file has been applied and removed
    metadata.removeValue(forKey: "appNewVersion")
    metadata.removeValue(forKey: "downloadURL")
    metadata.removeValue(forKey: "stagedTimestamp")
    metadata["installedTimestamp"] = timestamp
    do {
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: metadataURL, options: .atomic)
    } catch {
        Logger.log("⚠️ Failed to write install timestamp for \(label): \(error)")
    }
}


// MARK: - Download and Stage Updates

func downloadAndStageUpdates(bypassBandwidthLimit: Bool = false, labelFilter: String? = nil) {
    let stageStart = Date()
    let iso = ISO8601DateFormatter()
    Logger.log("⬇️ Staging started at \(iso.string(from: stageStart))")

    let prefs = Preferences()
    Logger.log("📋 Preferences source: \(prefs.source)")
    let failThreshold = prefs.stageDownloadFailThreshold
    let bandwidthLimit: String? = bypassBandwidthLimit ? nil : prefs.downloadBandwidthLimit
    if bypassBandwidthLimit {
        Logger.log("⚡ Bandwidth limit bypassed (stageOnDemand)")
    } else if let bandwidthLimit {
        Logger.log("🐢 Bandwidth limit active: \(bandwidthLimit)/s")
    }
    let ignoreAppsInHomeFolder = prefs.ignoreAppsInHomeFolder
    let ignoreUnknownVersionLabels = prefs.ignoreUnknownVersionLabels
    let unknownVersionCheckIntervalDays = prefs.unknownVersionCheckIntervalDays
    let versionMismatchThrottleDays = prefs.versionMismatchThrottleDays
    let currentInstallomatorVersion = loadEffectiveLabelsVersion()

    // Load previous apply broken state (versions abandoned after install failures)
    let previousApplyBrokenState = loadApplyBrokenState()
    var applyBrokenVersions = previousApplyBrokenState.brokenVersions

    // Load previous stage broken state
    let previousStageState = loadStageBrokenState()
    let stageBrokenAutoSkip: Set<String>
    var stageFailedAttempts = previousStageState.failedAttempts
    var newlyStageBrokenLabels: [String] = []

    if previousStageState.installomatorVersion == currentInstallomatorVersion && !currentInstallomatorVersion.isEmpty {
        stageBrokenAutoSkip = Set(previousStageState.labels)
    } else {
        // New Installomator version — reset broken state and attempt counts
        stageBrokenAutoSkip = []
        stageFailedAttempts = [:]
        Logger.log("ℹ️ Installomator version changed or first run — resetting stage broken labels")
    }

    if !stageBrokenAutoSkip.isEmpty {
        Logger.log("ℹ️ \(stageBrokenAutoSkip.count) stage-broken label(s) will be skipped (threshold: \(failThreshold))")
    }

    let discoveredFolderURL = AppConstants.patcherDiscoveredFolderURL
    let fileManager = FileManager.default

    do {
        var plistFiles = try fileManager.contentsOfDirectory(at: discoveredFolderURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "plist" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let labelFilter {
            plistFiles = plistFiles.filter { $0.deletingPathExtension().lastPathComponent == labelFilter }
        }

        var stagedCount = 0
        var alreadyStagedCount = 0
        var skippedCount = 0
        var brokenSkippedCount = 0
        var unknownIgnoredCount = 0
        var unknownThrottledCount = 0
        var versionMismatchThrottledCount = 0
        var unknownCheckedUpToDateCount = 0
        var failedCount = 0

        for plistURL in plistFiles {
            let label = plistURL.deletingPathExtension().lastPathComponent

            // Skip stage-broken labels
            if stageBrokenAutoSkip.contains(label) {
                Logger.log("--------------------------------------------------")
                Logger.log("🚫 Skipping \(label) — marked stage-broken (failed \(stageFailedAttempts[label] ?? failThreshold)+ times)")
                brokenSkippedCount += 1
                continue
            }

            guard let plistData = try? Data(contentsOf: plistURL),
                  let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
                Logger.log("⚠️ Could not read plist for \(label)")
                continue
            }

            // Only stage items that need an update or have unknown status
            let updateStatus = plist["updateStatus"] as? String ?? ""
            guard updateStatus == UpdateStatus.updateRequired.rawValue || updateStatus == UpdateStatus.unknown.rawValue else {
                Logger.log("--------------------------------------------------")
                Logger.log("⏭️ Skipping \(label) — status: \(updateStatus)")
                skippedCount += 1
                continue
            }

            // Skip if all installs are in a home folder and IgnoreAppsInHomeFolder is enabled
            if ignoreAppsInHomeFolder,
               let foundInstalls = plist["foundInstalls"] as? [[String: Any]],
               !foundInstalls.isEmpty,
               foundInstalls.allSatisfy({ ($0["path"] as? String ?? "").hasPrefix("/Users/") }) {
                Logger.log("--------------------------------------------------")
                Logger.log("⏭️ Skipping \(label) — all installs are in /Users/ (IgnoreAppsInHomeFolder)")
                skippedCount += 1
                continue
            }

            // Apply unknown-version policy: preference skip or time-based throttle
            if updateStatus == UpdateStatus.unknown.rawValue {
                if ignoreUnknownVersionLabels {
                    Logger.log("--------------------------------------------------")
                    Logger.log("⏭️ Skipping \(label) — unknown version items ignored (IgnoreUnknownVersionLabels)")
                    unknownIgnoredCount += 1
                    continue
                }
                if unknownVersionThrottleActive(label: label, intervalDays: unknownVersionCheckIntervalDays) {
                    Logger.log("--------------------------------------------------")
                    Logger.log("⏳ Skipping \(label) — unknown version check within \(unknownVersionCheckIntervalDays)-day throttle window")
                    unknownThrottledCount += 1
                    continue
                }
            }

            let appNewVersion = plist["appNewVersion"] as? String ?? ""

            // Skip labels whose last-attempted install version was abandoned after repeated failures.
            // If a newer version is now available, clear the broken state and allow staging to proceed.
            if let brokenVersion = applyBrokenVersions[label] {
                if appNewVersion == brokenVersion || appNewVersion.isEmpty {
                    Logger.log("--------------------------------------------------")
                    Logger.log("🚫 Skipping \(label) — v\(brokenVersion) was abandoned after \(prefs.applyFailThreshold) install failures")
                    brokenSkippedCount += 1
                    continue
                } else {
                    Logger.log("ℹ️ \(label) has new version v\(appNewVersion) (was broken at v\(brokenVersion)) — clearing apply-broken state")
                    applyBrokenVersions.removeValue(forKey: label)
                }
            }

            // Throttle re-downloads for labels where a previous download found the script-reported
            // version didn't match the actual packaged version. Invalidated automatically when
            // appNewVersion changes (meaning a genuine new release appeared).
            if updateStatus == UpdateStatus.updateRequired.rawValue {
                if unknownVersionThrottleActive(label: label, intervalDays: versionMismatchThrottleDays, currentAppNewVersion: appNewVersion) {
                    Logger.log("--------------------------------------------------")
                    Logger.log("⏳ Skipping \(label) — previously downloaded version matched installed, within \(versionMismatchThrottleDays)-day throttle window")
                    versionMismatchThrottledCount += 1
                    continue
                }
            }

            guard let downloadURLString = plist["downloadURL"] as? String, !downloadURLString.isEmpty,
                  let downloadURL = URL(string: downloadURLString) else {
                Logger.log("--------------------------------------------------")
                Logger.log("⚠️ Invalid or missing downloadURL for \(label)")
                failedCount += 1
                continue
            }

            guard let expectedTeamID = plist["expectedTeamID"] as? String, !expectedTeamID.isEmpty else {
                Logger.log("--------------------------------------------------")
                Logger.log("⚠️ Missing expectedTeamID for \(label)")
                failedCount += 1
                continue
            }

            guard let type = plist["type"] as? String, !type.isEmpty else {
                Logger.log("--------------------------------------------------")
                Logger.log("⚠️ Missing type for \(label)")
                failedCount += 1
                continue
            }

            // Check if this exact version and URL is already staged in the cache
            if let metadata = loadCacheMetadata(label: label),
               metadata["appNewVersion"] == appNewVersion,
               metadata["downloadURL"] == downloadURLString {
                Logger.log("--------------------------------------------------")
                Logger.log("✅ Already staged: \(label) v\(appNewVersion) — skipping download")
                alreadyStagedCount += 1
                continue
            }

            Logger.log("--------------------------------------------------")
            Logger.log("⬇️ Staging: \(label) v\(appNewVersion) (\(type))")
            Logger.log("   URL: \(downloadURLString)")

            // Create per-label cache directory
            let labelCacheURL = AppConstants.patcherCacheFolderURL.appendingPathComponent(label)
            do {
                try fileManager.createDirectory(at: labelCacheURL, withIntermediateDirectories: true)
            } catch {
                Logger.log("❌ Failed to create cache directory for \(label): \(error)")
                failedCount += 1
                continue
            }

            let fileName = resolveDownloadFilename(from: downloadURL, label: label, type: type)
            Logger.log("   File: \(fileName)")
            let destinationURL = labelCacheURL.appendingPathComponent(fileName)

            let curlOptions = plist["curlOptions"] as? String
            if let curlOptions, !curlOptions.isEmpty {
                Logger.log("   curlOptions: \(curlOptions)")
            }

            // Download
            Logger.log("⬇️ Downloading \(fileName)...")
            guard downloadFile(from: downloadURL, to: destinationURL, bandwidthLimit: bandwidthLimit, curlOptions: curlOptions) else {
                Logger.log("❌ Download failed for \(label)")
                failedCount += 1
                let attempts = (stageFailedAttempts[label] ?? 0) + 1
                stageFailedAttempts[label] = attempts
                Logger.log("   Failure count for \(label): \(attempts)/\(failThreshold)")
                if attempts >= failThreshold {
                    Logger.log("🚫 \(label) reached failure threshold — marking as stage-broken")
                    newlyStageBrokenLabels.append(label)
                }
                continue
            }
            Logger.log("✅ Download complete: \(destinationURL.path)")

            // Verify team ID
            Logger.log("🔍 Verifying Team ID for \(label) (expected: \(expectedTeamID))...")
            guard verifyTeamID(downloadedFilePath: destinationURL.path, type: type, expectedTeamID: expectedTeamID, label: label) else {
                Logger.log("❌ Team ID verification failed for \(label) — removing download")
                try? fileManager.removeItem(at: destinationURL)
                failedCount += 1
                let attempts = (stageFailedAttempts[label] ?? 0) + 1
                stageFailedAttempts[label] = attempts
                Logger.log("   Failure count for \(label): \(attempts)/\(failThreshold)")
                if attempts >= failThreshold {
                    Logger.log("🚫 \(label) reached failure threshold — marking as stage-broken")
                    newlyStageBrokenLabels.append(label)
                }
                continue
            }

            // Success — clear any previous failure count for this label
            stageFailedAttempts.removeValue(forKey: label)

            Logger.log("✅ Team ID verified for \(label)")

            // Always inspect the downloaded file to verify the actual version.
            // Scripts can report an appNewVersion that doesn't match what was packaged
            // (e.g. Spotify), which would cause unnecessary stage/apply cycles.
            let installedVersion = plist["installedVersion"] as? String ?? ""
            let versionKey       = plist["versionKey"]       as? String
            let packageID        = plist["packageID"]         as? String
            let appName          = plist["appName"]           as? String
            let name             = plist["name"]              as? String
            let expectedLabel    = appNewVersion.isEmpty ? "unknown" : appNewVersion
            Logger.log("🔍 Verifying downloaded version for \(label) (expected: \(expectedLabel), installed: \(installedVersion.isEmpty ? "unknown" : installedVersion))…")

            if let downloadedVersion = extractVersionFromDownloadedApp(
                filePath: destinationURL.path, type: type,
                versionKey: versionKey, packageID: packageID,
                appName: appName, name: name, label: label) {

                Logger.log("   Downloaded version: \(downloadedVersion)")
                if !appNewVersion.isEmpty && downloadedVersion != appNewVersion {
                    Logger.log("⚠️ Version mismatch for \(label): script reported \(appNewVersion), downloaded file is \(downloadedVersion)")
                }

                let versionOrder = installedVersion.isEmpty
                    ? ComparisonResult.orderedDescending
                    : downloadedVersion.compare(installedVersion, options: .numeric)

                if versionOrder == .orderedSame {
                    Logger.log("👍 No update needed — downloaded version matches installed (\(downloadedVersion))")
                    try? fileManager.removeItem(at: destinationURL)
                    updateDiscoveredPlist(label: label, updates: ["appNewVersion": downloadedVersion])
                    writeUnknownCheckMetadata(label: label, timestamp: iso.string(from: Date()), appNewVersion: appNewVersion, labelCacheURL: labelCacheURL)
                    unknownCheckedUpToDateCount += 1
                } else if versionOrder == .orderedAscending {
                    Logger.log("⏬ Would downgrade \(label): downloaded \(downloadedVersion) is older than installed \(installedVersion) — skipping")
                    try? fileManager.removeItem(at: destinationURL)
                    updateDiscoveredPlist(label: label, updates: ["appNewVersion": downloadedVersion, "updateStatus": UpdateStatus.wouldDowngrade.rawValue])
                    writeUnknownCheckMetadata(label: label, timestamp: iso.string(from: Date()), appNewVersion: appNewVersion, labelCacheURL: labelCacheURL)
                    unknownCheckedUpToDateCount += 1
                } else {
                    // Update confirmed — stage with the actual downloaded version
                    let arrow = installedVersion.isEmpty ? downloadedVersion : "\(installedVersion) → \(downloadedVersion)"
                    Logger.log("⬆️ Update confirmed: \(arrow)")
                    recordUpdateFoundIfNeeded(label: label, installedVersion: installedVersion,
                                              availableVersion: downloadedVersion, date: Date())
                    updateDiscoveredPlist(label: label, updates: [
                        "appNewVersion": downloadedVersion,
                        "updateStatus": UpdateStatus.updateRequired.rawValue
                    ])
                    cleanLabelCache(labelCacheURL, keeping: fileName)
                    writeCacheMetadata(label: label, appNewVersion: downloadedVersion, downloadURL: downloadURLString, timestamp: iso.string(from: Date()))
                    recordStaged(label: label, availableVersion: downloadedVersion, downloadURL: downloadURLString,
                                 stagedFilePath: labelCacheURL.appendingPathComponent(fileName).path, date: Date())
                    stagedCount += 1
                }
            } else {
                // Cannot extract version — fall back to script-reported appNewVersion if available
                let fallback = appNewVersion
                Logger.log("⚠️ Could not determine version from downloaded file for \(label) — staging with \(fallback.isEmpty ? "unknown version" : "script-reported version \(fallback)")")
                cleanLabelCache(labelCacheURL, keeping: fileName)
                writeCacheMetadata(label: label, appNewVersion: fallback, downloadURL: downloadURLString, timestamp: iso.string(from: Date()))
                recordStaged(label: label, availableVersion: fallback, downloadURL: downloadURLString,
                             stagedFilePath: labelCacheURL.appendingPathComponent(fileName).path, date: Date())
                stagedCount += 1
            }
        }

        // Compute updated broken labels — union if same version, fresh list if version changed
        let updatedStageBrokenLabels: [String]
        if previousStageState.installomatorVersion == currentInstallomatorVersion && !currentInstallomatorVersion.isEmpty {
            let combined = Set(previousStageState.labels).union(newlyStageBrokenLabels)
            updatedStageBrokenLabels = combined.sorted()
        } else {
            updatedStageBrokenLabels = newlyStageBrokenLabels.sorted()
        }

        let stageEnd = Date()
        let duration = stageEnd.timeIntervalSince(stageStart)
        Logger.log("--------------------------------------------------")
        Logger.log("✅ Staging complete — \(stagedCount) staged, \(alreadyStagedCount) already staged, \(skippedCount) skipped, \(brokenSkippedCount) broken-skipped, \(unknownIgnoredCount) unknown-ignored, \(unknownThrottledCount) unknown-throttled, \(versionMismatchThrottledCount) mismatch-throttled, \(unknownCheckedUpToDateCount) checked-up-to-date, \(failedCount) failed, \(String(format: "%.2f", duration))s")

        updateConfigJSON([
            "lastStageStart": iso.string(from: stageStart),
            "lastStageEnd": iso.string(from: stageEnd),
            "lastStageDurationSeconds": duration,
            "lastStagedCount": stagedCount,
            "lastStageAlreadyStagedCount": alreadyStagedCount,
            "lastStageSkippedCount": skippedCount,
            "lastStageBrokenSkippedCount": brokenSkippedCount,
            "lastStageUnknownIgnoredCount": unknownIgnoredCount,
            "lastStageUnknownThrottledCount": unknownThrottledCount,
            "lastStageVersionMismatchThrottledCount": versionMismatchThrottledCount,
            "lastStageUnknownCheckedUpToDateCount": unknownCheckedUpToDateCount,
            "lastStageFailedCount": failedCount,
            "stageBrokenLabels": updatedStageBrokenLabels,
            "stageInstallomatorVersion": currentInstallomatorVersion,
            "stageFailedAttempts": stageFailedAttempts,
            "applyBrokenVersions": applyBrokenVersions
        ])

    } catch {
        Logger.log("❌ Error during staging: \(error)")
    }
}

private func downloadFile(from url: URL, to destination: URL, bandwidthLimit: String? = nil, curlOptions: String? = nil) -> Bool {
    // Remove any stale file at the destination before downloading
    try? FileManager.default.removeItem(at: destination)

    // Use curl when a bandwidth limit or label-specific curl options are present
    if bandwidthLimit != nil || curlOptions != nil {
        return downloadFileWithCurl(from: url, to: destination, limitRate: bandwidthLimit, curlOptions: curlOptions)
    }

    let semaphore = DispatchSemaphore(value: 0)
    var success = false

    URLSession.shared.downloadTask(with: url) { tempURL, _, error in
        defer { semaphore.signal() }
        if let error {
            Logger.log("❌ Download error: \(error.localizedDescription)")
            return
        }
        guard let tempURL else { return }
        do {
            try FileManager.default.moveItem(at: tempURL, to: destination)
            success = true
        } catch {
            Logger.log("❌ Failed to move downloaded file: \(error)")
        }
    }.resume()

    semaphore.wait()
    return success
}

private func downloadFileWithCurl(from url: URL, to destination: URL, limitRate: String?, curlOptions: String?) -> Bool {
    var args: [String] = ["-L", "-o", destination.path, "--silent", "--show-error"]

    if let limitRate {
        args += ["--limit-rate", limitRate]
    }

    if let curlOptions, !curlOptions.isEmpty {
        args += shellSplit(curlOptions)
    }

    args.append(url.absoluteString)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    process.arguments = args
    process.standardOutput = Pipe()
    let errPipe = Pipe()
    process.standardError = errPipe
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        Logger.log("❌ curl launch error: \(error)")
        return false
    }
    guard process.terminationStatus == 0 else {
        let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        Logger.log("❌ curl failed (exit \(process.terminationStatus)): \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        return false
    }
    return FileManager.default.fileExists(atPath: destination.path)
}

/// Tokenizes a shell-style string into individual arguments, respecting single and double quotes.
/// e.g. `-H "User-Agent: foo bar"` → ["-H", "User-Agent: foo bar"]
private func shellSplit(_ string: String) -> [String] {
    var args: [String] = []
    var current = ""
    var inSingle = false
    var inDouble = false
    var i = string.startIndex

    while i < string.endIndex {
        let c = string[i]
        if inSingle {
            if c == "'" { inSingle = false }
            else { current.append(c) }
        } else if inDouble {
            if c == "\"" {
                inDouble = false
            } else if c == "\\" {
                let next = string.index(after: i)
                if next < string.endIndex { current.append(string[next]); i = next }
            } else {
                current.append(c)
            }
        } else {
            switch c {
            case "'":  inSingle = true
            case "\"": inDouble = true
            case "\\":
                let next = string.index(after: i)
                if next < string.endIndex { current.append(string[next]); i = next }
            default:
                if c.isWhitespace {
                    if !current.isEmpty { args.append(current); current = "" }
                } else {
                    current.append(c)
                }
            }
        }
        i = string.index(after: i)
    }
    if !current.isEmpty { args.append(current) }
    return args
}

/// Resolves the best filename for a download.
/// Priority: Content-Disposition header → URL last path component (if extension matches) → label.extension
private func resolveDownloadFilename(from url: URL, label: String, type: String) -> String {
    let expectedExtension: String
    switch type {
    case "dmg", "pkgInDmg":
        expectedExtension = "dmg"
    case "pkg":
        expectedExtension = "pkg"
    case "zip", "pkgInZip", "appInDmgInZip":
        expectedExtension = "zip"
    case "tbz":
        expectedExtension = "tbz"
    default:
        expectedExtension = type
    }

    // 1. Ask the server
    if let name = filenameFromContentDisposition(url: url), !name.isEmpty {
        Logger.log("   Filename from Content-Disposition: \(name)")
        return name
    }

    // 2. URL last path component — only accept if its extension matches the expected type
    let lastComponent = url.lastPathComponent
    if !lastComponent.isEmpty,
       (lastComponent as NSString).pathExtension.lowercased() == expectedExtension {
        return lastComponent
    }

    // 3. Fallback: label name with the correct extension
    return "\(label).\(expectedExtension)"
}

/// Issues a HEAD request and returns the filename from the Content-Disposition header, if present.
private func filenameFromContentDisposition(url: URL) -> String? {
    var request = URLRequest(url: url, timeoutInterval: 15)
    request.httpMethod = "HEAD"

    let semaphore = DispatchSemaphore(value: 0)
    var filename: String? = nil

    URLSession.shared.dataTask(with: request) { _, response, _ in
        defer { semaphore.signal() }
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let disposition = http.value(forHTTPHeaderField: "Content-Disposition") else { return }
        filename = parseContentDispositionFilename(disposition)
    }.resume()

    semaphore.wait()
    return filename
}

/// Parses a Content-Disposition header value and returns the filename.
/// Handles both `filename*=charset''encoded` (RFC 5987) and `filename="name"` forms.
private func parseContentDispositionFilename(_ disposition: String) -> String? {
    let parts = disposition.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }

    // Prefer filename*= (RFC 5987 — supports Unicode and percent-encoding)
    for part in parts where part.lowercased().hasPrefix("filename*=") {
        let value = String(part.dropFirst("filename*=".count)).trimmingCharacters(in: .whitespaces)
        // Format: charset'language'encoded-value  (e.g. UTF-8''My%20App.dmg)
        let tokens = value.components(separatedBy: "'")
        if tokens.count >= 3 {
            return tokens[2].removingPercentEncoding
        }
    }

    // Fall back to filename= (plain or quoted)
    for part in parts where part.lowercased().hasPrefix("filename=") {
        var value = String(part.dropFirst("filename=".count)).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }

    return nil
}


private func verifyTeamID(downloadedFilePath: String, type: String, expectedTeamID: String, label: String) -> Bool {
    let tempDir = AppConstants.patcherTempFolderURL.appendingPathComponent("verify_\(label)_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    do {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    } catch {
        Logger.log("❌ Failed to create verification temp directory: \(error)")
        return false
    }

    let foundTeamID: String?

    switch type {

    case "dmg":
        foundTeamID = withMountedDMG(at: downloadedFilePath) { mountPoint in
            findItem(ext: "app", in: mountPoint).flatMap { extractTeamID(fromApp: $0) }
        }

    case "pkg":
        foundTeamID = extractTeamID(fromPkg: downloadedFilePath)

    case "zip":
        foundTeamID = unzipped(filePath: downloadedFilePath, to: tempDir.path) {
            findItem(ext: "app", in: tempDir.path).flatMap { extractTeamID(fromApp: $0) }
        }

    case "tbz":
        foundTeamID = untarred(filePath: downloadedFilePath, to: tempDir.path) {
            findItem(ext: "app", in: tempDir.path).flatMap { extractTeamID(fromApp: $0) }
        }

    case "pkgInDmg":
        foundTeamID = withMountedDMG(at: downloadedFilePath) { mountPoint in
            findItem(ext: "pkg", in: mountPoint).flatMap { extractTeamID(fromPkg: $0) }
        }

    case "pkgInZip":
        foundTeamID = unzipped(filePath: downloadedFilePath, to: tempDir.path) {
            findItem(ext: "pkg", in: tempDir.path).flatMap { extractTeamID(fromPkg: $0) }
        }

    case "appInDmgInZip":
        foundTeamID = unzipped(filePath: downloadedFilePath, to: tempDir.path) {
            guard let dmgPath = findItem(ext: "dmg", in: tempDir.path) else { return nil }
            return withMountedDMG(at: dmgPath) { mountPoint in
                findItem(ext: "app", in: mountPoint).flatMap { extractTeamID(fromApp: $0) }
            }
        }

    default:
        Logger.log("⚠️ Unknown type '\(type)' — cannot verify Team ID")
        return false
    }

    guard let foundTeamID else {
        Logger.log("❌ Could not extract Team ID from downloaded \(type)")
        return false
    }

    Logger.log("🔍 Found Team ID: \(foundTeamID)")
    return foundTeamID == expectedTeamID
}

// MARK: - Staging helpers

/// Returns true if the DMG at the given path contains an SLA that would block programmatic mounting.
private func dmgHasSLA(at path: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    process.arguments = ["imageinfo", path, "-plist"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        Logger.log("⚠️ hdiutil imageinfo failed for \(path)")
        return false
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
          let properties = plist["Properties"] as? [String: Any],
          let hasSLA = properties["Software License Agreement"] as? Bool else {
        return false
    }
    return hasSLA
}

/// Converts an SLA-protected DMG to a plain UDRW image (removing the SLA) and replaces the
/// original file in place. Returns true on success.
private func convertDmgWithSLA(at path: String) -> Bool {
    let tempFileURL = AppConstants.patcherTempFolderURL.appendingPathComponent("sla_\(UUID().uuidString).dmg")
    defer { try? FileManager.default.removeItem(at: tempFileURL) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    process.arguments = ["convert", "-format", "UDRW", "-o", tempFileURL.path, path]
    process.standardOutput = Pipe()
    process.standardError = Pipe()

    guard (try? process.run()) != nil else {
        Logger.log("❌ Failed to launch hdiutil convert")
        return false
    }
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        Logger.log("❌ hdiutil convert failed (exit \(process.terminationStatus))")
        return false
    }
    guard FileManager.default.fileExists(atPath: tempFileURL.path) else {
        Logger.log("❌ Converted DMG not found at expected path")
        return false
    }

    do {
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.moveItem(atPath: tempFileURL.path, toPath: path)
    } catch {
        Logger.log("❌ Failed to replace DMG with converted version: \(error)")
        return false
    }

    return true
}

/// Mounts a DMG at a temporary mount point, runs the closure, then detaches.
/// Automatically handles SLA-protected DMGs by converting them before mounting.
private func withMountedDMG<T>(at filePath: String, body: (String) -> T?) -> T? {
    // Preflight: detect and remove SLA before mounting
    if dmgHasSLA(at: filePath) {
        Logger.log("⚠️ DMG contains an SLA — converting before mount...")
        guard convertDmgWithSLA(at: filePath) else {
            Logger.log("❌ Failed to convert SLA DMG at \(filePath)")
            return nil
        }
        Logger.log("✅ SLA removed — proceeding with mount")
    }

    let mountPoint = AppConstants.patcherTempFolderURL.appendingPathComponent("dmg_\(UUID().uuidString)").path
    try? FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)

    let attach = Process()
    attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    attach.arguments = ["attach", filePath, "-mountpoint", mountPoint, "-nobrowse", "-noverify", "-noautoopen", "-quiet"]
    attach.standardOutput = Pipe()
    attach.standardError = Pipe()

    guard (try? attach.run()) != nil else {
        try? FileManager.default.removeItem(atPath: mountPoint)
        return nil
    }
    attach.waitUntilExit()

    guard attach.terminationStatus == 0 else {
        Logger.log("❌ hdiutil attach failed (exit \(attach.terminationStatus))")
        try? FileManager.default.removeItem(atPath: mountPoint)
        return nil
    }

    defer {
        let detach = Process()
        detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        detach.arguments = ["detach", mountPoint, "-quiet"]
        detach.standardOutput = Pipe()
        detach.standardError = Pipe()
        try? detach.run()
        detach.waitUntilExit()
        try? FileManager.default.removeItem(atPath: mountPoint)
    }

    return body(mountPoint)
}

/// Unzips a file to a directory, runs the closure, returns its result (or nil on failure).
private func unzipped<T>(filePath: String, to directory: String, body: () -> T?) -> T? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-xk", filePath, directory]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        Logger.log("❌ ditto unzip failed (exit \(process.terminationStatus))")
        return nil
    }
    return body()
}

/// Untars a .tbz file to a directory, runs the closure, returns its result (or nil on failure).
private func untarred<T>(filePath: String, to directory: String, body: () -> T?) -> T? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = ["-xjf", filePath, "-C", directory]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        Logger.log("❌ tar failed (exit \(process.terminationStatus))")
        return nil
    }
    return body()
}

/// Returns the path of the first item with the given extension found recursively under a directory.
private func findItem(ext: String, in directory: String) -> String? {
    guard let enumerator = FileManager.default.enumerator(atPath: directory) else { return nil }
    for case let name as String in enumerator {
        if (name as NSString).pathExtension.lowercased() == ext.lowercased() {
            return (directory as NSString).appendingPathComponent(name)
        }
    }
    return nil
}

/// Returns the path of the first item whose last path component matches the given name (case-insensitive),
/// searching recursively under a directory.
private func findItemNamed(_ name: String, in directory: String) -> String? {
    guard let enumerator = FileManager.default.enumerator(atPath: directory) else { return nil }
    let target = name.lowercased()
    for case let relativePath as String in enumerator {
        if (relativePath as NSString).lastPathComponent.lowercased() == target {
            return (directory as NSString).appendingPathComponent(relativePath)
        }
    }
    return nil
}

/// Extracts the Team ID from a signed .app bundle via spctl (Gatekeeper assessment).
private func extractTeamID(fromApp appPath: String) -> String? {
    do {
        let result = try SignatureInspector.inspectAppSignature(appPath: appPath)
        guard result["Accepted"] as? Bool == true else {
            Logger.log("⚠️ App signature not accepted at \(appPath)")
            return nil
        }
        return result["DeveloperTeam"] as? String
    } catch {
        Logger.log("❌ Signature inspection failed for app at \(appPath): \(error)")
        return nil
    }
}

/// Extracts the Team ID from a signed .pkg via spctl (Gatekeeper assessment).
private func extractTeamID(fromPkg pkgPath: String) -> String? {
    do {
        let result = try SignatureInspector.inspectPackageSignature(pkgPath: pkgPath)
        guard result["Accepted"] as? Bool == true else {
            Logger.log("⚠️ Package signature not accepted at \(pkgPath)")
            return nil
        }
        return result["DeveloperTeam"] as? String
    } catch {
        Logger.log("❌ Signature inspection failed for pkg at \(pkgPath): \(error)")
        return nil
    }
}

/// Reads the version string from an .app bundle's Info.plist.
/// Uses versionKey if provided and non-empty, otherwise falls back to CFBundleShortVersionString.
private func readAppBundleVersion(atPath appPath: String, versionKey: String?) -> String? {
    let key = (versionKey?.isEmpty == false) ? versionKey! : "CFBundleShortVersionString"
    let infoPlistPath = "\(appPath)/Contents/Info.plist"
    guard let plistData = NSDictionary(contentsOfFile: infoPlistPath),
          let version = plistData[key] as? String else {
        Logger.log("⚠️ Could not read \(key) from \(infoPlistPath)")
        return nil
    }
    return version
}


/// Extracts the version from a downloaded file based on its Installomator type.
/// Handles app-based types (dmg, zip, tbz, appInDmgInZip) and pkg-based types (pkg, pkgInZip, pkgInDmgInZip).
private func extractVersionFromDownloadedApp(filePath: String, type fileType: String, versionKey: String?, packageID: String?, appName: String?, name: String?, label: String) -> String? {
    let tempDir = AppConstants.patcherTempFolderURL
        .appendingPathComponent("version-inspect-\(UUID().uuidString)")
        .path

    switch fileType {
    case "dmg":
        return withMountedDMG(at: filePath) { mountPoint in
            guard let appPath = findItem(ext: "app", in: mountPoint) else {
                Logger.log("⚠️ No .app found in DMG for \(label)")
                return nil
            }
            return readAppBundleVersion(atPath: appPath, versionKey: versionKey)
        }

    case "zip":
        do { try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true) } catch {}
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        return unzipped(filePath: filePath, to: tempDir) {
            guard let appPath = findItem(ext: "app", in: tempDir) else {
                Logger.log("⚠️ No .app found in ZIP for \(label)")
                return nil
            }
            return readAppBundleVersion(atPath: appPath, versionKey: versionKey)
        }

    case "tbz":
        do { try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true) } catch {}
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        return untarred(filePath: filePath, to: tempDir) {
            guard let appPath = findItem(ext: "app", in: tempDir) else {
                Logger.log("⚠️ No .app found in TBZ for \(label)")
                return nil
            }
            return readAppBundleVersion(atPath: appPath, versionKey: versionKey)
        }

    case "appInDmgInZip":
        do { try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true) } catch {}
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        return unzipped(filePath: filePath, to: tempDir) {
            guard let dmgPath = findItem(ext: "dmg", in: tempDir) else {
                Logger.log("⚠️ No .dmg found in ZIP for \(label)")
                return nil
            }
            return withMountedDMG(at: dmgPath) { mountPoint in
                guard let appPath = findItem(ext: "app", in: mountPoint) else {
                    Logger.log("⚠️ No .app found in DMG (inside ZIP) for \(label)")
                    return nil
                }
                return readAppBundleVersion(atPath: appPath, versionKey: versionKey)
            }
        }

    case "pkg":
        if let pkgID = packageID, !pkgID.isEmpty {
            return extractVersionFromExpandedPkg(pkgPath: filePath, packageID: packageID, versionKey: versionKey, label: label)
        } else {
            return extractVersionFromFullyExpandedPkg(pkgPath: filePath, appName: appName, name: name, versionKey: versionKey, label: label)
        }

    case "pkgInZip":
        do { try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true) } catch {}
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        return unzipped(filePath: filePath, to: tempDir) {
            guard let pkgPath = findItem(ext: "pkg", in: tempDir) else {
                Logger.log("⚠️ No .pkg found in ZIP for \(label)")
                return nil
            }
            if let pkgID = packageID, !pkgID.isEmpty {
                return extractVersionFromExpandedPkg(pkgPath: pkgPath, packageID: packageID, versionKey: versionKey, label: label)
            } else {
                return extractVersionFromFullyExpandedPkg(pkgPath: pkgPath, appName: appName, name: name, versionKey: versionKey, label: label)
            }
        }

    case "pkgInDmgInZip":
        do { try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true) } catch {}
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        return unzipped(filePath: filePath, to: tempDir) {
            guard let dmgPath = findItem(ext: "dmg", in: tempDir) else {
                Logger.log("⚠️ No .dmg found in ZIP for \(label)")
                return nil
            }
            return withMountedDMG(at: dmgPath) { mountPoint in
                guard let pkgPath = findItem(ext: "pkg", in: mountPoint) else {
                    Logger.log("⚠️ No .pkg found in DMG (inside ZIP) for \(label)")
                    return nil
                }
                if let pkgID = packageID, !pkgID.isEmpty {
                    return extractVersionFromExpandedPkg(pkgPath: pkgPath, packageID: packageID, versionKey: versionKey, label: label)
                } else {
                    return extractVersionFromFullyExpandedPkg(pkgPath: pkgPath, appName: appName, name: name, versionKey: versionKey, label: label)
                }
            }
        }

    default:
        Logger.log("⚠️ Unknown type '\(fileType)' for version inspection — skipping \(label)")
        return nil
    }
}


/// Expands a .pkg file with pkgutil and extracts the version from its Distribution or PackageInfo XML.
private func extractVersionFromExpandedPkg(pkgPath: String, packageID: String?, versionKey: String?, label: String) -> String? {
    let expandDir = AppConstants.patcherTempFolderURL
        .appendingPathComponent("pkg-expand-\(UUID().uuidString)")
        .path
    defer { try? FileManager.default.removeItem(atPath: expandDir) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
    process.arguments = ["--expand", pkgPath, expandDir]
    process.standardOutput = Pipe()
    let errPipe = Pipe()
    process.standardError = errPipe
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        Logger.log("❌ pkgutil --expand failed for \(label): \(error)")
        return nil
    }
    guard process.terminationStatus == 0 else {
        let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        Logger.log("❌ pkgutil --expand non-zero exit for \(label): \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        return nil
    }

    // Product archive: Distribution file at root
    let distributionPath = "\(expandDir)/Distribution"
    if FileManager.default.fileExists(atPath: distributionPath) {
        return extractVersionFromDistributionXML(atPath: distributionPath, packageID: packageID, versionKey: versionKey, label: label)
    }

    // Component package: PackageInfo at root
    let packageInfoPath = "\(expandDir)/PackageInfo"
    if FileManager.default.fileExists(atPath: packageInfoPath) {
        return extractVersionFromPackageInfoXML(atPath: packageInfoPath, label: label)
    }

    Logger.log("⚠️ No Distribution or PackageInfo found in expanded pkg for \(label)")
    return nil
}


/// Parses a Distribution XML file and returns the bundle version for the given packageID.
/// Falls back to the first bundle-version element found if the packageID doesn't match.
private func extractVersionFromDistributionXML(atPath path: String, packageID: String?, versionKey: String?, label: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path),
          let doc = try? XMLDocument(data: data, options: []) else {
        Logger.log("⚠️ Failed to parse Distribution XML for \(label)")
        return nil
    }

    let key = (versionKey?.isEmpty == false) ? versionKey! : "CFBundleShortVersionString"

    // Try the matching pkg-ref first
    if let pkgID = packageID, !pkgID.isEmpty {
        let xpath = "//pkg-ref[@id='\(pkgID)']/bundle-version/bundle/@\(key)"
        if let nodes = try? doc.nodes(forXPath: xpath),
           let value = nodes.first?.stringValue, !value.isEmpty {
            return value
        }
        Logger.log("ℹ️ No bundle version for packageID '\(pkgID)' in Distribution for \(label) — trying any pkg-ref")
    }

    // Fallback: first bundle-version element anywhere in the document
    let xpath = "//bundle-version/bundle/@\(key)"
    if let nodes = try? doc.nodes(forXPath: xpath),
       let value = nodes.first?.stringValue, !value.isEmpty {
        return value
    }

    // Fallback: version attribute on <pkg-ref> elements.
    if let pkgID = packageID, !pkgID.isEmpty {
        let xpathPkgRef = "//pkg-ref[@id='\(pkgID)']/@version"
        if let nodes = try? doc.nodes(forXPath: xpathPkgRef) {
            for node in nodes {
                let value = node.stringValue ?? ""
                if !value.isEmpty, !value.split(separator: ".").allSatisfy({ $0 == "0" }) {
                    Logger.log("ℹ️ Found version from pkg-ref[@version] for '\(pkgID)' in Distribution for \(label)")
                    return value
                }
            }
        }
    }

    // Last resort: any pkg-ref with a non-zero version attribute
    let xpathAnyPkgRef = "//pkg-ref/@version"
    if let nodes = try? doc.nodes(forXPath: xpathAnyPkgRef) {
        for node in nodes {
            let value = node.stringValue ?? ""
            if !value.isEmpty, !value.split(separator: ".").allSatisfy({ $0 == "0" }) {
                Logger.log("ℹ️ Found version from any pkg-ref[@version] in Distribution for \(label)")
                return value
            }
        }
    }

    Logger.log("⚠️ No bundle version found in Distribution XML for \(label)")
    return nil
}


/// Parses a PackageInfo XML file and returns the version attribute from the root pkg-info element.
private func extractVersionFromPackageInfoXML(atPath path: String, label: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path),
          let doc = try? XMLDocument(data: data, options: []) else {
        Logger.log("⚠️ Failed to parse PackageInfo XML for \(label)")
        return nil
    }
    if let nodes = try? doc.nodes(forXPath: "/pkg-info/@version"),
       let value = nodes.first?.stringValue, !value.isEmpty {
        return value
    }
    Logger.log("⚠️ No version attribute found in PackageInfo for \(label)")
    return nil
}


/// Fully expands a .pkg (including its Payload) and reads the version from the enclosed .app bundle.
/// Used when no packageID is available to drive XML-based version extraction.
/// Searches for appName.app first, then name.app, then any .app as a last resort.
private func extractVersionFromFullyExpandedPkg(pkgPath: String, appName: String?, name: String?, versionKey: String?, label: String) -> String? {
    let expandDir = AppConstants.patcherTempFolderURL
        .appendingPathComponent("pkg-full-expand-\(UUID().uuidString)")
        .path
    defer { try? FileManager.default.removeItem(atPath: expandDir) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
    process.arguments = ["--expand-full", pkgPath, expandDir]
    process.standardOutput = Pipe()
    let errPipe = Pipe()
    process.standardError = errPipe
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        Logger.log("❌ pkgutil --expand-full failed for \(label): \(error)")
        return nil
    }
    guard process.terminationStatus == 0 else {
        let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        Logger.log("❌ pkgutil --expand-full non-zero exit for \(label): \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        return nil
    }

    // Determine the target .app bundle name: appName > name + ".app" > any .app
    let appPath: String?
    if let appName = appName, !appName.isEmpty {
        let target = appName.hasSuffix(".app") ? appName : "\(appName).app"
        appPath = findItemNamed(target, in: expandDir) ?? findItem(ext: "app", in: expandDir)
        if appPath == nil { Logger.log("⚠️ '\(target)' not found in fully expanded pkg for \(label) — no .app fallback found either") }
    } else if let name = name, !name.isEmpty {
        let target = "\(name).app"
        appPath = findItemNamed(target, in: expandDir) ?? findItem(ext: "app", in: expandDir)
        if appPath == nil { Logger.log("⚠️ '\(target)' not found in fully expanded pkg for \(label) — no .app fallback found either") }
    } else {
        appPath = findItem(ext: "app", in: expandDir)
        if appPath == nil { Logger.log("⚠️ No .app found in fully expanded pkg for \(label)") }
    }

    guard let resolvedAppPath = appPath else { return nil }
    Logger.log("   Found app bundle at: \(resolvedAppPath)")
    return readAppBundleVersion(atPath: resolvedAppPath, versionKey: versionKey)
}


/// Removes all files in a label's cache directory except metadata.json and the newly staged file.
/// Call this after a successful download before writing cache metadata.
private func cleanLabelCache(_ labelCacheURL: URL, keeping newFileName: String) {
    guard let contents = try? FileManager.default.contentsOfDirectory(at: labelCacheURL, includingPropertiesForKeys: nil) else { return }
    for fileURL in contents {
        let name = fileURL.lastPathComponent
        guard name != "metadata.json", name != LabelHistory.fileName, name != newFileName else { continue }
        do {
            try FileManager.default.removeItem(at: fileURL)
            Logger.log("🗑️ Removed stale cache file: \(name)")
        } catch {
            Logger.log("⚠️ Could not remove stale cache file \(name): \(error)")
        }
    }
}


/// Writes a metadata.json file to the label's cache directory recording what was staged.
/// This is the authoritative record of what is currently in the cache — not the discovered plist.
func writeCacheMetadata(label: String, appNewVersion: String, downloadURL: String, timestamp: String) {
    let metadataURL = AppConstants.patcherCacheFolderURL
        .appendingPathComponent(label)
        .appendingPathComponent("metadata.json")
    let metadata: [String: String] = [
        "appNewVersion": appNewVersion,
        "downloadURL": downloadURL,
        "stagedTimestamp": timestamp
    ]
    do {
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: metadataURL, options: .atomic)
        Logger.log("💾 Wrote cache metadata for \(label)")
    } catch {
        Logger.log("❌ Failed to write cache metadata for \(label): \(error)")
    }
}

/// Reads the metadata.json from the label's cache directory.
/// Returns nil if the file doesn't exist or can't be parsed.
func loadCacheMetadata(label: String) -> [String: String]? {
    let metadataURL = AppConstants.patcherCacheFolderURL
        .appendingPathComponent(label)
        .appendingPathComponent("metadata.json")
    guard let data = try? Data(contentsOf: metadataURL),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
        return nil
    }
    return dict
}


/// Returns true if a label was recently downloaded, found up-to-date, and should be throttled.
/// Pass `currentAppNewVersion` to enable automatic invalidation: if appNewVersion changed since
/// the throttle was written (e.g. a real update arrived), the throttle is ignored.
private func unknownVersionThrottleActive(label: String, intervalDays: Int, currentAppNewVersion: String = "") -> Bool {
    let metadataURL = AppConstants.patcherCacheFolderURL
        .appendingPathComponent(label)
        .appendingPathComponent("metadata.json")
    guard let data = try? Data(contentsOf: metadataURL),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let timestampStr = json["lastCheckedUpToDateTimestamp"] as? String else {
        return false
    }
    // If a version was recorded at throttle time and it no longer matches, a real update arrived.
    if !currentAppNewVersion.isEmpty,
       let throttledAt = json["throttledAtAppNewVersion"] as? String,
       throttledAt != currentAppNewVersion {
        return false
    }
    let iso = ISO8601DateFormatter()
    guard let lastChecked = iso.date(from: timestampStr) else { return false }
    let daysSince = Calendar.current.dateComponents([.day], from: lastChecked, to: Date()).day ?? Int.max
    return daysSince < intervalDays
}


/// Writes up-to-date check metadata to the label's cache directory.
/// Records the timestamp and the appNewVersion that was active at check time (for throttle invalidation).
/// The count only resets when a new version is actually detected (new metadata.json written by writeCacheMetadata).
private func writeUnknownCheckMetadata(label: String, timestamp: String, appNewVersion: String = "", labelCacheURL: URL) {
    let metadataURL = labelCacheURL.appendingPathComponent("metadata.json")
    var existingCount = 0
    if let data = try? Data(contentsOf: metadataURL),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        existingCount = json["unknownVersionCheckCount"] as? Int ?? 0
    }
    let newCount = existingCount + 1
    var metadata: [String: Any] = [
        "lastCheckedUpToDateTimestamp": timestamp,
        "unknownVersionCheckCount": newCount
    ]
    if !appNewVersion.isEmpty {
        metadata["throttledAtAppNewVersion"] = appNewVersion
    }
    do {
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: metadataURL, options: .atomic)
        Logger.log("💾 Wrote up-to-date check metadata for \(label) (check #\(newCount))")
    } catch {
        Logger.log("⚠️ Failed to write up-to-date check metadata for \(label): \(error)")
    }
}


// MARK: - Managed label resolution

/// Returns the URL for a label's `.sh` file, preferring a managed override when present.
/// Checks `managedLabelsFolderURL/<name>.sh` first, falls back to
/// `installomatorLabelsFolderURL/<name>.sh`. Returns nil if neither exists.
func resolveLabel(name: String) -> URL? {
    let managed = AppConstants.managedLabelsFolderURL.appendingPathComponent("\(name).sh")
    if FileManager.default.fileExists(atPath: managed.path) {
        return managed
    }
    guard !Preferences().installomatorLabelsDisable else { return nil }
    let standard = AppConstants.installomatorLabelsFolderURL.appendingPathComponent("\(name).sh")
    return FileManager.default.fileExists(atPath: standard.path) ? standard : nil
}

/// Builds the combined, sorted label file list for a scan.
/// Starts from Installomator labels, then overlays any `.sh` files found in the
/// managed labels folder — overriding same-named Installomator labels and adding new ones.
/// Logs a summary of overrides and additions.
func buildLabelFileList() -> [URL] {
    let fm = FileManager.default
    let prefs = Preferences()

    // Base: Installomator labels keyed by label name (skipped when disabled by preference)
    var labelMap: [String: URL] = [:]
    if prefs.installomatorLabelsDisable {
        Logger.log("ℹ️ Installomator labels disabled — using managed labels only.")
    } else if let installomatorFiles = try? fm.contentsOfDirectory(
        at: AppConstants.installomatorLabelsFolderURL, includingPropertiesForKeys: nil
    ) {
        for url in installomatorFiles where url.pathExtension == "sh" {
            labelMap[url.deletingPathExtension().lastPathComponent] = url
        }
    }

    // Overlay: managed labels
    var overrideNames: [String] = []
    var additionNames: [String] = []

    if fm.fileExists(atPath: AppConstants.managedLabelsFolderURL.path),
       let managedFiles = try? fm.contentsOfDirectory(
           at: AppConstants.managedLabelsFolderURL, includingPropertiesForKeys: nil
       ) {
        for url in managedFiles where url.pathExtension == "sh" {
            let name = url.deletingPathExtension().lastPathComponent
            if labelMap[name] != nil {
                overrideNames.append(name)
            } else {
                additionNames.append(name)
            }
            labelMap[name] = url
        }
    }

    if !overrideNames.isEmpty {
        Logger.log("📦 Managed label overrides (\(overrideNames.count)): \(overrideNames.sorted().joined(separator: ", "))")
    }
    if !additionNames.isEmpty {
        Logger.log("📦 Managed label additions (\(additionNames.count)): \(additionNames.sorted().joined(separator: ", "))")
    }

    return labelMap.values.sorted { $0.lastPathComponent < $1.lastPathComponent }
}


/// Merges updates into an existing discovered plist without overwriting unrelated keys.
func updateDiscoveredPlist(label: String, updates: [String: Any]) {
    let plistURL = AppConstants.patcherDiscoveredFolderURL.appendingPathComponent("\(label).plist")
    guard let data = try? Data(contentsOf: plistURL),
          var plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
        Logger.log("⚠️ Could not read discovered plist for \(label)")
        return
    }
    for (key, value) in updates { plist[key] = value }
    do {
        let updated = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try updated.write(to: plistURL, options: .atomic)
    } catch {
        Logger.log("❌ Failed to update discovered plist for \(label): \(error)")
    }
}


// MARK: - Dialog interaction recording

/// Records the outcome of the deferral prompt against every pending label.
/// Defined here (patcher-only) because DeferralPromptResult is patcher-only.
func recordDeferralOutcome(labels: [String], result: DeferralPromptResult, date: Date) {
    let event: LabelHistoryEvent
    switch result {
    case .proceed:
        event = .userContinued(date: date)
    case .deferred(let minutes):
        event = .userDeferred(date: date, minutes: minutes)
    case .timedOutDeferred(let minutes):
        event = .timedOutDeferred(date: date, minutes: minutes)
    case .deadlineForced:
        event = .deadlineForced(date: date)
    }
    for label in labels {
        LabelHistory.append(event: event, label: label)
    }
    Logger.verbose("📖 History: deferral outcome '\(event.type)' recorded for \(labels.count) label(s)")
}


// MARK: - Ensure status

/// Updates the `status` field in `active_phase.json` during a `patcher ensure` run.
/// The scheduler writes the file before launching patcher and removes it after; this
/// function updates it in-place so the UI can show granular progress.
func writeEnsureStatus(_ status: String) {
    let url = AppConstants.patcherConfigFolderURL.appendingPathComponent("active_phase.json")
    var dict: [String: Any] = [:]
    if let data = try? Data(contentsOf: url),
       let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        dict = existing
    }
    dict["status"] = status
    if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Cleanup after run
func cleanupAfterRun() {
    do {
        try FileManager.default.removeItem(atPath: AppConstants.patcherTempFolderURL.path)
        Logger.log("Deleted directory: \(AppConstants.patcherTempFolderURL.path)")
    } catch {
        Logger.log("Failed to delete directory: \(error)")
    }
}
