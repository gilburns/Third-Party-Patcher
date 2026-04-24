//
//  PatcherMenuViewModel.swift
//  PatcherMenu
//
//  Created by Gil Burns on 4/22/26.
//

import Foundation
import Combine

@MainActor
final class PatcherMenuViewModel: ObservableObject {

    // MARK: - Published state

    @Published var schedulerState: SchedulerStateData?
    @Published var deferralState: DeferralStateData?
    @Published var stagedPatches: [StagedPatch] = []
    @Published var preferences = Preferences()
    @Published var lastRefreshed = Date()
    @Published var isLoading = false

    // MARK: - Data models (local read-only copies)

    struct SchedulerStateData: Codable {
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
    }

    struct StagedPatch: Identifiable {
        let id: String          // Installomator label key
        let displayName: String
        let newVersion: String
        let stagedDate: Date?
    }

    // MARK: - Computed properties

    var hasPendingPatches: Bool { !stagedPatches.isEmpty }

    var deferralCount: Int { deferralState?.count ?? schedulerState?.deferralCount ?? 0 }

    var nextPromptDate: Date? {
        guard let expiry = deferralState?.expiryDate, expiry > Date() else { return nil }
        return expiry
    }

    /// Reference date from which deadlines are measured:
    /// firstPendingDate in deadline-based mode, most recent patch day in monthly mode.
    var deadlineReference: Date? {
        guard schedulerState?.firstPendingDate != nil else { return nil }
        return preferences.monthlyPatchingCadenceEnabled
            ? mostRecentPatchDay()
            : schedulerState?.firstPendingDate
    }

    var hardDeadlineDate: Date? {
        deadlineReference.flatMap {
            Calendar.current.date(byAdding: .day, value: preferences.deadlineDaysHard, to: $0)
        }
    }

    var focusDeadlineDate: Date? {
        deadlineReference.flatMap {
            Calendar.current.date(byAdding: .day, value: preferences.deadlineDaysFocus, to: $0)
        }
    }

    var daysUntilHardDeadline: Int? {
        hardDeadlineDate.map {
            Calendar.current.dateComponents([.day], from: Date(), to: $0).day ?? 0
        }
    }

    /// Next upcoming patch day (monthly mode only; nil in deadline-based mode or if none found).
    var nextPatchDay: Date? {
        guard preferences.monthlyPatchingCadenceEnabled else { return nil }
        let cal = Calendar.current
        let now = Date()
        let y = cal.component(.year, from: now)
        let m = cal.component(.month, from: now)
        for offset in 0...1 {
            var mo = m + offset, yr = y
            if mo > 12 { mo -= 12; yr += 1 }
            var c = DateComponents()
            c.year = yr; c.month = mo
            c.weekday = preferences.patchingWeekday
            c.weekdayOrdinal = preferences.patchingWeekOfMonth
            if let d = cal.date(from: c), d >= now { return d }
        }
        return nil
    }

    var refreshedAgo: String {
        let s = Date().timeIntervalSince(lastRefreshed)
        if s < 60 { return "just now" }
        return "\(Int(s / 60))m ago"
    }

    // MARK: - Init

    private var refreshTimer: Timer?

    init() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    // MARK: - Refresh

    func refresh() {
        isLoading = true
        schedulerState = loadSchedulerState()
        deferralState = loadDeferralState()
        preferences = Preferences()
        stagedPatches = loadStagedPatches()
        lastRefreshed = Date()
        isLoading = false
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
        let cacheURL = AppConstants.patcherCacheFolderURL
        guard let subdirs = try? FileManager.default.contentsOfDirectory(
            at: cacheURL, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        let iso = ISO8601DateFormatter()
        var patches: [StagedPatch] = []

        for dir in subdirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let label = dir.lastPathComponent

            // Staged update = at least one file that isn't metadata.json or history.json
            let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            guard contents.contains(where: {
                $0.lastPathComponent != "metadata.json" && $0.lastPathComponent != "history.json"
            }) else { continue }

            // metadata.json must have stagedTimestamp (stripped after install)
            let metaURL = dir.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let version = meta["appNewVersion"],
                  let tsString = meta["stagedTimestamp"]
            else { continue }

            let stagedDate = iso.date(from: tsString)
            let displayName = discoveredDisplayName(for: label) ?? label

            patches.append(StagedPatch(
                id: label,
                displayName: displayName,
                newVersion: version,
                stagedDate: stagedDate
            ))
        }

        return patches.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
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

    // MARK: - Monthly patch day calculation

    func mostRecentPatchDay() -> Date? {
        let cal = Calendar.current
        let now = Date()
        let y = cal.component(.year, from: now)
        let m = cal.component(.month, from: now)
        for offset in 0...1 {
            var mo = m - offset, yr = y
            if mo <= 0 { mo += 12; yr -= 1 }
            var c = DateComponents()
            c.year = yr; c.month = mo
            c.weekday = preferences.patchingWeekday
            c.weekdayOrdinal = preferences.patchingWeekOfMonth
            if let d = cal.date(from: c), d <= now { return d }
        }
        return nil
    }
}
