//
//  AvailableSoftwareViewModel.swift
//  Available Software
//
//  Created by Gil Burns on 4/25/26.
//

import Foundation
import AppKit
import Combine

@MainActor
final class AvailableSoftwareViewModel: ObservableObject {

    @Published var preferences  = Preferences()
    @Published var activePhase: String?
    @Published var activeLabel: String?
    @Published var activeStatus: String?
    @Published var queuedLabel: String?

    // MARK: - My Software data

    @Published var stagedPatches: [StagedPatch]  = []
    @Published var managedApps:   [ManagedApp]   = []
    @Published var updateHistory: [HistoryEntry] = []

    struct StagedPatch: Identifiable {
        let id: String          // Installomator label
        let displayName: String
        let newVersion: String
        let stagedDate: Date?
        let iconURL: URL?
    }

    struct ManagedApp: Identifiable {
        let id: String          // Installomator label
        let displayName: String
        let updateStatus: String    // "upToDate" | "updateRequired" | "userSpace" | "unknown"
        let iconURL: URL?
        let installPaths: [String]  // all paths from foundInstalls
        let publisher: String?
        let appDescription: String?
        let keywords: [String]
        let category: String?
        let isThrottled: Bool       // true if within the version-mismatch throttle window (stage will skip it)

        var primaryAppPath: String? {
            // Prefer a non-user-space .app; fall back to any .app
            installPaths.first(where: { $0.hasSuffix(".app") && !$0.hasPrefix("/Users/") })
                ?? installPaths.first(where: { $0.hasSuffix(".app") })
        }
    }

    struct HistoryEntry: Identifiable {
        let id = UUID()
        let label: String
        let displayName: String
        let date: Date
        let eventType: String       // "applied" | "selfService" | "discovered"
        let fromVersion: String?
        let toVersion: String?
        let iconURL: URL?
    }

    // MARK: - Private

    private var xpcConnection: NSXPCConnection?
    private var configDirWatcher: DispatchSourceFileSystemObject?
    private var configDirFD: Int32 = -1
    private var wasActive = false       // tracks phase transition for My Software refresh
    private var appliedIconPath: String? // icon path last applied to the Dock/Finder

    init() {
        appliedIconPath = Preferences().customAppIconPath
        startConfigDirWatch()
        loadMySoftwareData()
    }

    deinit {
        configDirWatcher?.cancel()
        if configDirFD >= 0 { close(configDirFD) }
    }

    // MARK: - Config directory watcher

    private func startConfigDirWatch() {
        let path = AppConstants.patcherConfigFolderURL.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        configDirFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.reloadActivePhase() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        configDirWatcher = source

        reloadActivePhase()
    }

    private func reloadActivePhase() {
        let url = AppConstants.patcherConfigFolderURL.appendingPathComponent("active_phase.json")
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let phase = dict["phase"] as? String
        else {
            // No active phase — all activity has stopped; clear any queued state
            let completedPhase = activePhase
            let completedLabel = activeLabel
            activePhase = nil
            activeLabel = nil
            activeStatus = nil
            queuedLabel = nil
            // Refresh My Software data when a patcher phase finishes
            if wasActive {
                loadMySoftwareData()
                if completedPhase == "install", let label = completedLabel {
                    addInstalledAppToDock(label: label)
                }
            }
            wasActive = false
            return
        }
        wasActive = true
        activePhase = phase
        activeLabel = dict["label"] as? String
        activeStatus = dict["status"] as? String
        // Transition: label moved from queued → actively running
        if let activeLabel, activeLabel == queuedLabel {
            queuedLabel = nil
        }
    }

    private func addInstalledAppToDock(label: String) {
        guard preferences.addToDockOnSelfServiceInstall else { return }

        var appPath: String?

        // Primary: foundInstalls in the discovered plist, written by patcher after install
        let discoveredURL = AppConstants.patcherDiscoveredFolderURL.appendingPathComponent("\(label).plist")
        if let data = try? Data(contentsOf: discoveredURL),
           let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {

            let foundInstalls = dict["foundInstalls"] as? [[String: Any]] ?? []
            appPath = foundInstalls
                .compactMap { $0["path"] as? String }
                .first(where: { $0.hasSuffix(".app") && !$0.hasPrefix("/Users/") })
                ?? foundInstalls
                .compactMap { $0["path"] as? String }
                .first(where: { $0.hasSuffix(".app") })

            // Fallback: construct path from name if foundInstalls is empty
            if appPath == nil, let name = dict["name"] as? String, !name.isEmpty {
                let candidate = "/Applications/\(name).app"
                if FileManager.default.fileExists(atPath: candidate) {
                    appPath = candidate
                }
            }
            // Fallback: construct path from name if foundInstalls is empty
            if appPath == nil, let name = dict["appName"] as? String, !name.isEmpty {
                let candidate = "/Applications/\(name)"
                if FileManager.default.fileExists(atPath: candidate) {
                    appPath = candidate
                }
            }
        }

        // Fallback: managedApps (already loaded by loadMySoftwareData above)
        if appPath == nil {
            appPath = managedApps.first(where: { $0.id == label })?.primaryAppPath
        }

        guard let resolvedPath = appPath else {
            NSLog("DockManager: could not resolve app path for label %@", label)
            return
        }

        DockManager.addApp(at: resolvedPath)
    }

    // MARK: - XPC

    func installLabel(_ label: String) {
        guard queuedLabel == nil && activeLabel == nil else { return }
        queuedLabel = label

        if xpcConnection == nil { setupXPCConnection() }
        guard let proxy = xpcConnection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            NSLog("AvailableSoftware XPC error: %@", error.localizedDescription)
            Task { @MainActor [weak self] in
                self?.xpcConnection = nil
                self?.queuedLabel = nil
            }
        }) as? PatcherXPCProtocol else {
            NSLog("AvailableSoftware XPC: failed to obtain proxy for installLabel '\(label)'")
            queuedLabel = nil
            return
        }
        proxy.installLabel(label) { [weak self] success, message in
            NSLog("AvailableSoftware XPC installLabel reply: success=%d message=%@", success, message)
            if !success {
                Task { @MainActor [weak self] in self?.queuedLabel = nil }
            }
        }
    }

    /// Triggers the apply phase to install all staged pending updates.
    func triggerApply() {
        guard activeLabel == nil else { return }
        if xpcConnection == nil { setupXPCConnection() }
        guard let proxy = xpcConnection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            NSLog("AvailableSoftware XPC error (apply): %@", error.localizedDescription)
            Task { @MainActor [weak self] in self?.xpcConnection = nil }
        }) as? PatcherXPCProtocol else { return }
        proxy.triggerPhase("apply") { _, _ in }
    }

    /// Triggers the stage phase to download pending updates.
    func triggerStage() {
        guard activeLabel == nil else { return }
        if xpcConnection == nil { setupXPCConnection() }
        guard let proxy = xpcConnection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            NSLog("AvailableSoftware XPC error (stage): %@", error.localizedDescription)
            Task { @MainActor [weak self] in self?.xpcConnection = nil }
        }) as? PatcherXPCProtocol else { return }
        proxy.triggerPhase("stage") { _, _ in }
    }

    /// Triggers the check phase to look for available updates.
    func triggerCheck() {
        guard activeLabel == nil else { return }
        if xpcConnection == nil { setupXPCConnection() }
        guard let proxy = xpcConnection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            NSLog("AvailableSoftware XPC error (check): %@", error.localizedDescription)
            Task { @MainActor [weak self] in self?.xpcConnection = nil }
        }) as? PatcherXPCProtocol else { return }
        proxy.triggerPhase("check") { _, _ in }
    }

    /// Triggers the scan phase for full discovery of installed applications.
    func triggerScan() {
        guard activeLabel == nil else { return }
        if xpcConnection == nil { setupXPCConnection() }
        guard let proxy = xpcConnection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            NSLog("AvailableSoftware XPC error (scan): %@", error.localizedDescription)
            Task { @MainActor [weak self] in self?.xpcConnection = nil }
        }) as? PatcherXPCProtocol else { return }
        proxy.triggerPhase("scan") { _, _ in }
    }

    private func setupXPCConnection() {
        let conn = NSXPCConnection(machServiceName: AppConstants.patcherXPCServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: PatcherXPCProtocol.self)
        conn.invalidationHandler = { NSLog("AvailableSoftware XPC connection invalidated") }
        conn.interruptionHandler = { NSLog("AvailableSoftware XPC connection interrupted") }
        conn.resume()
        xpcConnection = conn
    }

    // MARK: - Icon change detection

    func checkIconChange() {
        let newPath = Preferences().customAppIconPath
        guard newPath != appliedIconPath else { return }
        appliedIconPath = newPath

        // Ask the daemon to apply the Finder icon change immediately (root required).
        let bundlePath = Bundle.main.bundlePath
        if xpcConnection == nil { setupXPCConnection() }
        guard let proxy = xpcConnection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            NSLog("AvailableSoftware iconChange XPC error: %@", error.localizedDescription)
            Task { @MainActor [weak self] in self?.xpcConnection = nil }
        }) as? PatcherXPCProtocol else { return }

        proxy.setAppIcon(iconPath: newPath, bundlePath: bundlePath) { success, message in
            NSLog("AvailableSoftware setAppIcon (change): success=%d message=%@", success, message)
            guard success else { return }
            Task { @MainActor in self.promptRelaunch() }
        }
    }

    private func promptRelaunch() {
        let alert = NSAlert()
        alert.messageText = "App Icon Changed"
        alert.informativeText = "The app icon preference has been updated. Relaunch to apply the new icon to the Dock and app switcher."
        alert.addButton(withTitle: "Relaunch Now")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .informational
        if alert.runModal() == .alertFirstButtonReturn {
            relaunchApp()
        }
    }

    private func relaunchApp() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Brief delay lets the current process fully tear down before the new one opens.
        task.arguments = ["-c", "sleep 0.5 && open \"\(bundlePath)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: - Scheduler activity snapshot (read-only, for the About panel)

    struct SchedulerActivitySnapshot: Codable {
        var lastScanDate:     Date?
        var lastCheckDate:    Date?
        var lastStageDate:    Date?
        var lastApplyDate:    Date?
        var lastMetaSyncDate: Date?
    }

    @Published var schedulerSnapshot: SchedulerActivitySnapshot?

    private func loadSchedulerSnapshot() -> SchedulerActivitySnapshot? {
        let url = AppConstants.patcherConfigFolderURL.appendingPathComponent("scheduler_state.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SchedulerActivitySnapshot.self, from: data)
    }

    // MARK: - My Software loaders

    func loadMySoftwareData() {
        checkIconChange()
        preferences      = Preferences()
        stagedPatches    = buildStagedPatches()
        managedApps      = buildManagedApps()
        updateHistory    = buildUpdateHistory()
        schedulerSnapshot = loadSchedulerSnapshot()
        updateDockBadge()
    }

    private func updateDockBadge() {
        let count = managedApps.filter { $0.updateStatus == "updateRequired" && !$0.isThrottled }.count
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : ""
    }

    private func buildStagedPatches() -> [StagedPatch] {
        let cacheURL = AppConstants.patcherCacheFolderURL
        guard let subdirs = try? FileManager.default.contentsOfDirectory(
            at: cacheURL, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        let iso = ISO8601DateFormatter()
        var result: [StagedPatch] = []

        for dir in subdirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let label = dir.lastPathComponent

            // Staged update = directory has at least one file that isn't metadata/history
            let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            guard contents.contains(where: {
                $0.lastPathComponent != "metadata.json" && $0.lastPathComponent != "history.json"
            }) else { continue }

            let metaURL = dir.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let version = meta["appNewVersion"],
                  let tsString = meta["stagedTimestamp"]
            else { continue }

            result.append(StagedPatch(
                id: label,
                displayName: resolveDisplayName(for: label),
                newVersion: version,
                stagedDate: iso.date(from: tsString),
                iconURL: resolveIconURL(for: label)
            ))
        }

        return result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func isVersionMismatchThrottled(label: String, currentAppNewVersion: String) -> Bool {
        let metadataURL = AppConstants.patcherCacheFolderURL
            .appendingPathComponent(label)
            .appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestampStr = json["lastCheckedUpToDateTimestamp"] as? String
        else { return false }
        if !currentAppNewVersion.isEmpty,
           let throttledAt = json["throttledAtAppNewVersion"] as? String,
           throttledAt != currentAppNewVersion {
            return false
        }
        let iso = ISO8601DateFormatter()
        guard let lastChecked = iso.date(from: timestampStr) else { return false }
        let daysSince = Calendar.current.dateComponents([.day], from: lastChecked, to: Date()).day ?? Int.max
        return daysSince < preferences.versionMismatchThrottleDays
    }

    private func buildManagedApps() -> [ManagedApp] {
        let discoveredURL = AppConstants.patcherDiscoveredFolderURL
        guard let plists = try? FileManager.default.contentsOfDirectory(
            at: discoveredURL, includingPropertiesForKeys: nil
        ) else { return [] }

        let ignoreUserSpace = preferences.ignoreAppsInHomeFolder

        var result: [ManagedApp] = []
        for plist in plists where plist.pathExtension == "plist" {
            let label = plist.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: plist),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }

            let name = dict["name"] as? String ?? (label.prefix(1).uppercased() + label.dropFirst())

            // Extract all install paths from foundInstalls.
            let foundInstalls = dict["foundInstalls"] as? [[String: Any]] ?? []
            let installPaths = foundInstalls.compactMap { $0["path"] as? String }.filter { !$0.isEmpty }

            // Determine whether all known install paths are in user space.
            let allUserSpace = !installPaths.isEmpty && installPaths.allSatisfy { $0.hasPrefix("/Users/") }

            let status: String
            if allUserSpace && ignoreUserSpace {
                // IgnoreAppsInHomeFolder = true — patcher will never update this app.
                status = "userSpace"
            } else {
                status = dict["updateStatus"] as? String ?? "unknown"
            }

            let isThrottled: Bool
            if status == "updateRequired" {
                let availableVersion = dict["appNewVersion"] as? String ?? ""
                isThrottled = isVersionMismatchThrottled(label: label, currentAppNewVersion: availableVersion)
            } else {
                isThrottled = false
            }

            let meta = loadManagedAppMetadata(for: label)
            result.append(ManagedApp(
                id:             label,
                displayName:    name,
                updateStatus:   status,
                iconURL:        resolveIconURL(for: label),
                installPaths:   installPaths,
                publisher:      meta.publisher,
                appDescription: meta.description,
                keywords:       meta.keywords,
                category:       meta.category,
                isThrottled:    isThrottled
            ))
        }

        return result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Loads publisher, description, keywords, and category for a label from local
    /// managed metadata or the synced metadata repo. No remote fetch — these are
    /// installed apps and the fields are only needed for search.
    private func loadManagedAppMetadata(for label: String) -> (publisher: String?, description: String?, keywords: [String], category: String?) {
        let langCode = Locale.preferredLanguages.first?.components(separatedBy: "-").first ?? "en"
        let bases = [
            AppConstants.managedMetadataFolderURL,
            AppConstants.installomatorMetadataFolderURL.appendingPathComponent("Metadata")
        ]
        for base in bases {
            let candidates: [URL] = langCode == "en"
                ? [base.appendingPathComponent("\(label).plist")]
                : [base.appendingPathComponent("\(langCode)/\(label).plist"),
                   base.appendingPathComponent("\(label).plist")]
            for url in candidates {
                guard FileManager.default.fileExists(atPath: url.path),
                      let data = try? Data(contentsOf: url),
                      let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                else { continue }
                let kw = (dict["Keywords"] as? String ?? "")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                return (
                    publisher:   dict["Publisher"]   as? String,
                    description: dict["Description"] as? String,
                    keywords:    kw,
                    category:    dict["Category"]    as? String
                )
            }
        }
        return (nil, nil, [], nil)
    }

    private func buildUpdateHistory() -> [HistoryEntry] {
        let cacheURL = AppConstants.patcherCacheFolderURL
        guard let subdirs = try? FileManager.default.contentsOfDirectory(
            at: cacheURL, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        let iso = ISO8601DateFormatter()
        var result: [HistoryEntry] = []

        for dir in subdirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let label = dir.lastPathComponent
            let historyURL = dir.appendingPathComponent("history.json")
            guard let data = try? Data(contentsOf: historyURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawEvents = json["events"] as? [[String: Any]]
            else { continue }

            let name    = resolveDisplayName(for: label)
            let icon    = resolveIconURL(for: label)
            var pending = false

            for raw in rawEvents {
                guard let type = raw["type"] as? String,
                      let dateStr = raw["date"] as? String,
                      let date = iso.date(from: dateStr)
                else { continue }

                switch type {
                case "selfServiceInstall":
                    pending = true
                case "applied":
                    result.append(HistoryEntry(
                        label: label, displayName: name, date: date,
                        eventType: pending ? "selfService" : "applied",
                        fromVersion: raw["fromVersion"] as? String,
                        toVersion:   raw["toVersion"]   as? String,
                        iconURL: icon
                    ))
                    pending = false
                case "discovered":
                    result.append(HistoryEntry(
                        label: label, displayName: name, date: date,
                        eventType: "discovered",
                        fromVersion: nil,
                        toVersion: raw["installedVersion"] as? String,
                        iconURL: icon
                    ))
                default:
                    break
                }
            }
        }

        return result.sorted { $0.date > $1.date }
    }

    // MARK: - Private helpers

    private func resolveDisplayName(for label: String) -> String {
        let url = AppConstants.patcherDiscoveredFolderURL.appendingPathComponent("\(label).plist")
        if let data = try? Data(contentsOf: url),
           let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let name = dict["name"] as? String, !name.isEmpty {
            return name
        }
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    private func resolveIconURL(for label: String) -> URL? {
        // 1. Admin-managed icons (highest priority — intentional overrides).
        let managed = AppConstants.managedIconsFolderURL.appendingPathComponent("\(label).png")
        if FileManager.default.fileExists(atPath: managed.path) { return managed }
        // 2. Locally synced metadata repo (fast, works offline after first sync).
        let synced = AppConstants.installomatorMetadataFolderURL
            .appendingPathComponent("Icons")
            .appendingPathComponent("\(label).png")
        if FileManager.default.fileExists(atPath: synced.path) { return synced }
        // 3. Remote fallback (used before first sync or for labels with no local icon).
        let base = "https://raw.githubusercontent.com/"
            + "\(preferences.installomatorGitHubMetadataAccount)/"
            + "\(preferences.installomatorGitHubMetadataRepo)/"
            + "refs/heads/\(preferences.installomatorGitHubMetadataBranch)/Icons/"
        return URL(string: base + "\(label).png")
    }
}
