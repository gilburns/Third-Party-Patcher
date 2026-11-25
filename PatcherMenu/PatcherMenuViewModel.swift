//
//  PatcherMenuViewModel.swift
//  PatcherMenu
//
//  Created by Gil Burns on 4/22/26.
//

import AppKit
import Combine

@MainActor
final class PatcherMenuViewModel: ObservableObject {

    // MARK: - Published state

    @Published var schedulerState: SchedulerStateData?
    @Published var deferralState: DeferralStateData?
    @Published var stagedPatches: [StagedPatch] = []
    @Published var detectedPatches: [DetectedPatch] = []
    @Published var hasDiscoveredApps = false
    @Published var preferences = Preferences()
    @Published var lastRefreshed = Date()
    @Published var isLoading = false
    @Published var activePhase: String?
    @Published var activeLabel: String?

    // MARK: - Data models (local read-only copies)

    struct SchedulerStateData: Codable {
        var firstLaunchDate: Date?
        var initialScanDelaySeconds: Int?
        var initialScanDelayEndedByUserDate: Date?
        var lastScanDate: Date?
        var lastCheckDate: Date?
        var lastStageDate: Date?
        var lastApplyDate: Date?
        var firstPendingDate: Date?
        var deferralCount: Int = 0
    }

    struct DeferralStateData: Codable {
        var expiryDate: Date?
        var count: Int = 0
        var userDeferralCount: Int = 0
        var timedOutDeferralCount: Int = 0
        var blockingProcessDeferralCount: Int = 0

        private enum CodingKeys: String, CodingKey {
            case expiryDate, count, userDeferralCount, timedOutDeferralCount, blockingProcessDeferralCount
        }

        // Lenient decode — the split counters were added after the first releases,
        // so older deferral_state.json files won't carry them.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            expiryDate                   = try c.decodeIfPresent(Date.self, forKey: .expiryDate)
            count                        = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
            userDeferralCount            = try c.decodeIfPresent(Int.self, forKey: .userDeferralCount) ?? 0
            timedOutDeferralCount        = try c.decodeIfPresent(Int.self, forKey: .timedOutDeferralCount) ?? 0
            blockingProcessDeferralCount = try c.decodeIfPresent(Int.self, forKey: .blockingProcessDeferralCount) ?? 0
        }
    }

    enum DeferralCountDisplay {
        case combined, split, userOnly
    }

    struct StagedPatch: Identifiable {
        let id: String          // Installomator label key
        let displayName: String
        let newVersion: String
        let stagedDate: Date?
        let installPaths: [String]
    }

    struct DetectedPatch: Identifiable {
        let id: String          // Installomator label key
        let displayName: String
        let availableVersion: String?
        let installPaths: [String]
    }

    // MARK: - Computed properties

    /// True when this process was started by the PatcherMenu LaunchAgent. launchd sets
    /// XPC_SERVICE_NAME to the job label; LaunchServices launches (Finder, `open`) do not.
    /// Quitting a LaunchAgent copy is pointless — KeepAlive relaunches it immediately.
    let launchedByLaunchAgent =
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == AppConstants.patcherMenuLaunchAgentLabel

    var hasPendingPatches: Bool { !stagedPatches.isEmpty }

    var hasDetectedUpdates: Bool { !detectedPatches.isEmpty }

    var deferralCount: Int { deferralState?.count ?? schedulerState?.deferralCount ?? 0 }

    /// Deferrals the user actively chose in the prompt.
    var userDeferralCount: Int { deferralState?.userDeferralCount ?? 0 }

    /// Auto-deferrals: prompt timer time-outs plus blocking-process skips.
    var autoDeferralCount: Int {
        (deferralState?.timedOutDeferralCount ?? 0) + (deferralState?.blockingProcessDeferralCount ?? 0)
    }

    var deferralCountDisplay: DeferralCountDisplay {
        switch preferences.menuDeferralCountDisplay.lowercased() {
        case "combined": return .combined
        case "useronly": return .userOnly
        default:         return .split
        }
    }

    /// The deferral-count line shown in the popover, honoring `MenuDeferralCountDisplay`.
    /// Singular/plural forms ("1 time" / "2 times") live in Localizable.xcstrings.
    var deferralCountText: String {
        switch deferralCountDisplay {
        case .combined:
            return String(localized: "Deferred \(deferralCount) times (includes auto-deferrals)",
                          comment: "Deferral count line. %lld = total deferrals, user-chosen plus automatic.")
        case .split:
            return String(localized: "Deferred \(userDeferralCount) times by you · \(autoDeferralCount) times automatically",
                          comment: "Deferral count line. First %lld = deferrals the user chose; second = automatic ones (prompt timed out, or an app was blocking the update).")
        case .userOnly:
            return String(localized: "Deferred \(userDeferralCount) times by you",
                          comment: "Deferral count line. %lld = deferrals the user chose.")
        }
    }

    /// A coarse "how long until" bucket. The menu turns each case into a whole sentence,
    /// so every sentence is one translatable string rather than an English fragment
    /// spliced into another string.
    enum ApproximateWait: Equatable {
        case hours(Int), minutes(Int), soon

        /// "3 hr" / "45 min", formatted for the user's language.
        var formattedDuration: String {
            switch self {
            case .hours(let h):
                return Duration.seconds(h * 3600).formatted(.units(allowed: [.hours], width: .abbreviated))
            case .minutes(let m):
                return Duration.seconds(m * 60).formatted(.units(allowed: [.minutes], width: .abbreviated))
            case .soon:
                return ""
            }
        }

        /// Hours above one hour, then minutes rounded up to the nearest 5 down to one
        /// scheduler cycle (600 s), then "soon".
        init(remaining: TimeInterval) {
            if remaining > 3600 {
                self = .hours(Int(ceil(remaining / 3600)))
            } else if remaining > 600 {
                self = .minutes(Int(ceil(remaining / 300)) * 5)
            } else {
                self = .soon
            }
        }
    }

    /// Approximately when the next apply prompt will appear.
    /// Coarsely bucketed — no exact countdown — because the prompt fires on the next
    /// scheduler cycle (up to 10 min) after the deferral expires.
    /// Returns nil once the deferral has been expired long enough that the scheduler
    /// has almost certainly run already.
    var nextPromptWait: ApproximateWait? {
        guard let expiry = deferralState?.expiryDate else { return nil }
        let remaining = expiry.timeIntervalSince(Date())
        // Scheduler cycle is 600 s. After expiry the prompt fires on the next wake,
        // so "soon" honestly covers both the tail of the deferral and the post-expiry window.
        guard remaining > -600 else { return nil }  // expired more than one full cycle ago — scheduler has run
        return ApproximateWait(remaining: remaining)
    }

    /// The "Next prompt: …" line, or nil when there is no pending prompt to announce.
    var nextPromptText: String? {
        switch nextPromptWait {
        case nil:
            return nil
        case .soon:
            return String(localized: "Next prompt: soon",
                          comment: "When the next update prompt will appear.")
        case let wait?:
            return String(localized: "Next prompt: in about \(wait.formattedDuration)",
                          comment: "When the next update prompt will appear. %@ = a short duration such as “3 hr” or “45 min”.")
        }
    }

    /// When the one-time initial deployment delay ends. Nil when the delay is disabled,
    /// not yet recorded by the scheduler, ended early by a user-initiated scan, or
    /// finished and the first scan has run.
    var initialDelayEndDate: Date? {
        guard preferences.initialScanDelayEnabled,
              schedulerState?.initialScanDelayEndedByUserDate == nil,
              let firstLaunch = schedulerState?.firstLaunchDate,
              let delay = schedulerState?.initialScanDelaySeconds
        else { return nil }
        let end = firstLaunch.addingTimeInterval(TimeInterval(delay))
        // Keep showing "soon" after the delay ends until the scheduler's first scan lands.
        if end <= Date() && schedulerState?.lastScanDate != nil { return nil }
        return end
    }

    /// The "Update checks start …" line shown during the initial delay.
    /// Bucketed like `nextPromptWait` — work begins on the first scheduler wake after
    /// the delay ends, so an exact countdown would overstate precision.
    var initialDelayText: String? {
        guard let end = initialDelayEndDate else { return nil }
        switch ApproximateWait(remaining: end.timeIntervalSince(Date())) {
        case .soon:
            return String(localized: "Update checks start soon",
                          comment: "Shown during the initial deployment delay, before the first scan.")
        case let wait:
            return String(localized: "Update checks start in about \(wait.formattedDuration)",
                          comment: "Shown during the initial deployment delay. %@ = a short duration such as “3 hr” or “45 min”.")
        }
    }

    private var schedule: PatchSchedule { PatchSchedule(prefs: preferences) }

    /// Reference date from which deadlines are measured.
    /// Monthly mode: this month's patch day — nil until it has passed (no active deadline yet).
    /// Deadline mode: firstPendingDate.
    var deadlineReference: Date? {
        schedule.deadlineReference(firstPendingDate: schedulerState?.firstPendingDate)
    }

    var hardDeadlineDate: Date? {
        schedule.hardDeadlineDate(firstPendingDate: schedulerState?.firstPendingDate)
    }

    var focusDeadlineDate: Date? {
        schedule.focusDeadlineDate(firstPendingDate: schedulerState?.firstPendingDate)
    }

    var daysUntilHardDeadline: Int? {
        hardDeadlineDate.map {
            Calendar.current.dateComponents([.day], from: Date(), to: $0).day ?? 0
        }
    }

    /// Next upcoming patch day (monthly mode only; nil in deadline-based mode or if none found).
    var nextPatchDay: Date? {
        guard preferences.monthlyPatchingCadenceEnabled else { return nil }
        return schedule.nextPatchDay()
    }

    /// The "Refreshed …" line under the header title.
    var refreshedText: String {
        if Date().timeIntervalSince(lastRefreshed) < 60 {
            return String(localized: "Refreshed just now",
                          comment: "Header subtitle: the menu's data was reloaded less than a minute ago.")
        }
        let ago = lastRefreshed.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
        return String(localized: "Refreshed \(ago)",
                      comment: "Header subtitle. %@ = a relative time such as “5 min. ago”, already formatted for the user's language.")
    }

    // MARK: - Init

    private var refreshTimer: Timer?
    private var xpcConnection: NSXPCConnection?
    private var configDirWatcher: DispatchSourceFileSystemObject?
    private var configDirFD: Int32 = -1

    init() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        startConfigDirWatch()
    }

    deinit {
        configDirWatcher?.cancel()
        if configDirFD >= 0 { close(configDirFD) }
    }

    // MARK: - Refresh

    func refresh() {
        isLoading = true
        schedulerState = loadSchedulerState()
        deferralState = loadDeferralState()
        preferences = Preferences()
        stagedPatches = loadStagedPatches()
        detectedPatches = loadDetectedPatches(excluding: stagedPatches)
        hasDiscoveredApps = discoveredAppsExist()
        lastRefreshed = Date()
        isLoading = false
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
            let wasActive = activePhase != nil
            activePhase = nil
            activeLabel = nil
            if wasActive { refresh() }
            return
        }
        activePhase = phase
        activeLabel = dict["label"] as? String
    }

    // MARK: - XPC

    /// Triggers a scheduler phase immediately via XPC, then refreshes state after a short delay.
    func triggerPhase(_ phase: String) {
        if xpcConnection == nil { setupXPCConnection() }
        guard let proxy = xpcConnection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            NSLog("PatcherMenu XPC error: %@", error.localizedDescription)
            Task { @MainActor [weak self] in
                self?.xpcConnection = nil
                self?.isLoading = false
            }
        }) as? PatcherXPCProtocol else {
            NSLog("PatcherMenu XPC: failed to obtain proxy for phase '\(phase)'")
            return
        }

        isLoading = true
        proxy.triggerPhase(phase) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.refresh()
            }
        }
    }

    private func setupXPCConnection() {
        let conn = NSXPCConnection(machServiceName: AppConstants.patcherXPCServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: PatcherXPCProtocol.self)
        conn.invalidationHandler = {
            NSLog("PatcherMenu XPC connection invalidated")
            Task { @MainActor in }
        }
        conn.interruptionHandler = {
            NSLog("PatcherMenu XPC connection interrupted")
        }
        conn.resume()
        xpcConnection = conn
    }

    // MARK: - Loaders

    private func loadSchedulerState() -> SchedulerStateData? {
        let url = AppConstants.patcherConfigFolderURL.appendingPathComponent("scheduler_state.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SchedulerStateData.self, from: data)
    }

    private func loadDeferralState() -> DeferralStateData? {
        let url = AppConstants.patcherConfigFolderURL.appendingPathComponent("deferral_state.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DeferralStateData.self, from: data)
    }

    private func loadStagedPatches() -> [StagedPatch] {
        let patches = StagedCache.entries().map { entry in
            StagedPatch(
                id: entry.label,
                displayName: discoveredDisplayName(for: entry.label) ?? entry.label,
                newVersion: entry.appNewVersion,
                stagedDate: entry.stagedDate,
                installPaths: discoveredInstallPaths(for: entry.label)
            )
        }

        return patches.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func loadDetectedPatches(excluding staged: [StagedPatch]) -> [DetectedPatch] {
        let stagedIDs = Set(staged.map(\.id))

        // Load stage-level and apply-level exclusions from config.json so the count
        // matches what the stage phase would actually attempt to download.
        let configExcluded = loadStageExclusions()

        let discoveredURL = AppConstants.patcherDiscoveredFolderURL
        guard let plists = try? FileManager.default.contentsOfDirectory(
            at: discoveredURL, includingPropertiesForKeys: nil
        ) else { return [] }

        let ignoreAppsInHomeFolder = preferences.ignoreAppsInHomeFolder

        var patches: [DetectedPatch] = []
        for plist in plists where plist.pathExtension == "plist" {
            let label = plist.deletingPathExtension().lastPathComponent

            guard !stagedIDs.contains(label) else { continue }
            guard !configExcluded.contains(label) else { continue }
            guard let data = try? Data(contentsOf: plist),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let status = dict["updateStatus"] as? String, status == "updateRequired"
            else { continue }

            // Mirror stage phase: skip if all installs are in /Users/ and IgnoreAppsInHomeFolder is enabled
            if ignoreAppsInHomeFolder,
               let foundInstalls = dict["foundInstalls"] as? [[String: Any]],
               !foundInstalls.isEmpty,
               foundInstalls.allSatisfy({ ($0["path"] as? String ?? "").hasPrefix("/Users/") }) {
                continue
            }

            // Mirror stage phase: skip if label is within the version-mismatch throttle window
            let availableVersion = dict["appNewVersion"] as? String ?? ""
            if isVersionMismatchThrottled(label: label, currentAppNewVersion: availableVersion,
                                          intervalDays: preferences.versionMismatchThrottleDays) {
                continue
            }

            // Also exclude apply-broken labels whose broken version matches the available version
            if let brokenVersion = configExcluded.applyBrokenVersion(for: label),
               availableVersion == brokenVersion || availableVersion.isEmpty {
                continue
            }

            let version = dict["appNewVersion"] as? String
            let name = dict["name"] as? String ?? label
            patches.append(DetectedPatch(id: label, displayName: name, availableVersion: version,
                                         installPaths: installPaths(from: dict)))
        }
        return patches.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func isVersionMismatchThrottled(label: String, currentAppNewVersion: String, intervalDays: Int) -> Bool {
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
        return daysSince < intervalDays
    }

    private func loadStageExclusions() -> StageExclusions {
        guard let data = try? Data(contentsOf: AppConstants.patcherConfigFileURL),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return StageExclusions(broken: [], applyBroken: [:]) }
        let broken = config["stageBrokenLabels"] as? [String] ?? []
        let applyBroken = config["applyBrokenVersions"] as? [String: String] ?? [:]
        return StageExclusions(broken: broken, applyBroken: applyBroken)
    }

    private struct StageExclusions {
        let broken: [String]
        let applyBroken: [String: String]

        func contains(_ label: String) -> Bool { broken.contains(label) }
        func applyBrokenVersion(for label: String) -> String? { applyBroken[label] }
    }

    private func discoveredDisplayName(for label: String) -> String? {
        let url = AppConstants.patcherDiscoveredFolderURL
            .appendingPathComponent("\(label).plist")
        guard let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let name = dict["name"] as? String, !name.isEmpty
        else { return nil }
        return name
    }

    private func discoveredInstallPaths(for label: String) -> [String] {
        let url = AppConstants.patcherDiscoveredFolderURL
            .appendingPathComponent("\(label).plist")
        guard let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [] }
        return installPaths(from: dict)
    }

    /// The recorded install paths the apply phase would actually patch. Mirrors
    /// resolveInstallTargets: /Users/ copies are skipped when IgnoreAppsInHomeFolder is on.
    /// (With ConvertAppsInHomeFolder the /Users/ copy is what gets replaced, so it stays.)
    private func installPaths(from dict: [String: Any]) -> [String] {
        let foundInstalls = dict["foundInstalls"] as? [[String: Any]] ?? []
        let ignoreAppsInHomeFolder = preferences.ignoreAppsInHomeFolder
        return foundInstalls
            .compactMap { $0["path"] as? String }
            .filter { !$0.isEmpty && !(ignoreAppsInHomeFolder && $0.hasPrefix("/Users/")) }
    }

    // MARK: - Finder reveal

    /// Selects the item's installed copies in Finder, skipping any that no longer exist.
    /// Returns false when there was nothing to reveal.
    @discardableResult
    func revealInFinder(_ paths: [String]) -> Bool {
        let urls = paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return false }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        return true
    }

    /// Opens the label's cache folder in Finder (staged installer, metadata.json, history.json).
    /// Returns false when the folder doesn't exist.
    @discardableResult
    func openCacheFolder(for label: String) -> Bool {
        let labelDir = StagedCache.labelDirectory(for: label)
        guard FileManager.default.fileExists(atPath: labelDir.path) else { return false }
        return NSWorkspace.shared.open(labelDir)
    }

}
