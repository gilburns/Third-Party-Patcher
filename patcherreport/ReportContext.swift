//
//  ReportContext.swift
//  patcher
//
//  Created by Gil Burns on 4/15/26.
//

import Foundation

// MARK: - Shared data loader

struct ReportContext {
    let now:              Date
    /// All labels that have a history.json, sorted alphabetically.
    let histories:        [(label: String, history: LabelHistory)]
    /// Discovered-plist dicts keyed by label name.
    let discoveredPlists: [String: [String: Any]]
    /// Contents of config.json.
    let config:           [String: Any]
    /// Managed / local preferences (deadline thresholds, patching cadence, …).
    let prefs:            Preferences
    /// Snapshot of the scheduler's persistent state (firstPendingDate, lastApplyDate).
    let schedulerState:   SchedulerStateSnapshot

    init() {
        now = Date()
        prefs = Preferences()
        schedulerState = SchedulerStateSnapshot.load()
        let fm = FileManager.default

        // History files: Cache/<label>/history.json
        var hs: [(String, LabelHistory)] = []
        if let dirs = try? fm.contentsOfDirectory(
                at: AppConstants.patcherCacheFolderURL,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) {
            for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let label = dir.lastPathComponent
                if let h = LabelHistory.load(label: label) { hs.append((label, h)) }
            }
        }
        histories = hs

        // Discovered plists: Discovered/<label>.plist
        var plists: [String: [String: Any]] = [:]
        if let files = try? fm.contentsOfDirectory(
                at: AppConstants.patcherDiscoveredFolderURL,
                includingPropertiesForKeys: nil
            ) {
            for file in files where file.pathExtension == "plist" {
                let label = file.deletingPathExtension().lastPathComponent
                if let data = try? Data(contentsOf: file),
                   let dict = try? PropertyListSerialization.propertyList(
                        from: data, options: [], format: nil) as? [String: Any] {
                    plists[label] = dict
                }
            }
        }
        discoveredPlists = plists

        // Config.json
        if let data = try? Data(contentsOf: AppConstants.patcherConfigFileURL),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = dict
        } else {
            config = [:]
        }
    }

    /// Parses an ISO-8601 date string from config by key.
    func configDate(_ key: String) -> Date? {
        guard let str = config[key] as? String else { return nil }
        return ISO8601DateFormatter().date(from: str)
    }
}

