//
//  LabelTracker.swift
//  patcher
//
//  Fallback to Installomator-Tracker data for labels that fail to resolve locally.
//

import Foundation

/// Reads Installomator-Tracker's `label_status.json` — the latest appNewVersion and
/// downloadURL its hourly GitHub Actions run resolved for every Installomator label —
/// and uses it when a label fails to resolve locally.
///
/// Tracker values are a hint, not a trust decision: they are only used when the tracker's
/// name, type and expectedTeamID match the local label, and staging still verifies every
/// download against the local label's Team ID and extracts the real version from it.
enum LabelTracker {

    struct Entry {
        let label: String
        let name: String
        let type: String
        let expectedTeamID: String
        let appNewVersion: String
        let downloadURL: String
        let downloadURLi386: String
        let status: String
        let timeStamp: String

        /// The tracker resolved this label to a version and an absolute http(s) URL.
        /// http is fine here: every download is upgraded to https (see httpsUpgraded).
        var resolved: Bool {
            guard status == "success", !appNewVersion.isEmpty,
                  let url = URL(string: downloadURL),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  !(url.host ?? "").isEmpty else { return false }
            return true
        }
    }

    /// Keys every label run outputs and processScriptData requires.
    static let scriptOutputKeys = [
        "appCustomVersion", "appName", "appNewVersion", "archiveName", "blockingProcesses",
        "CLIArguments", "CLIInstaller", "curlOptions", "downloadURL", "expectedTeamID",
        "installerTool", "label", "name", "packageID", "pkgName", "targetDir", "timeStamp",
        "type", "updateTool", "updateToolArguments", "updateToolRunAsCurrentUser", "versionKey"
    ]

    /// Tracker files whose `generatedAt` is older than this are ignored as stale.
    private static let maxGeneratedAge: TimeInterval = 48 * 3600
    /// A cached copy is used when the tracker can't be reached, if fetched within this window.
    private static let maxCacheAge: TimeInterval = 24 * 3600

    private static let download = CachedDownload(
        what: "Installomator-Tracker data",
        cacheURL: AppConstants.patcherConfigFolderURL.appendingPathComponent("label_tracker.json"),
        cacheMetaURL: AppConstants.patcherConfigFolderURL.appendingPathComponent("label_tracker_meta.plist"),
        maxCacheAge: maxCacheAge)

    /// Entries keyed by label, loaded on first use (once per process). Nil when the
    /// fallback is disabled or no usable tracker data could be loaded.
    private static let entries: [String: Entry]? = load()

    // MARK: - Queries

    /// The tracker's entry for a label, when the tracker currently resolves it.
    static func resolvedEntry(for label: String) -> Entry? {
        guard let entry = entries?[label], entry.resolved else { return nil }
        return entry
    }

    /// True when a label on the broken list should be retried instead of skipped: the
    /// tracker currently resolves it, so its local failure may have been transient.
    /// Never true for managed labels or when the fallback is disabled.
    static func shouldRetryBrokenLabel(_ label: String) -> Bool {
        let managed = AppConstants.managedLabelsFolderURL.appendingPathComponent("\(label).sh")
        guard !FileManager.default.fileExists(atPath: managed.path) else { return false }
        return resolvedEntry(for: label) != nil   // entries is nil when the fallback is disabled
    }

    // MARK: - Fallback

    /// Returns label output built from tracker values for a label that failed locally,
    /// or nil when the fallback doesn't apply.
    ///
    /// Applies only when the failure looks transient or external:
    /// - the run timed out (base values come from the label's last Discovered/Scanned plist), or
    /// - the run produced JSON with name, type and expectedTeamID but no downloadURL.
    ///
    /// A label that exited without output (e.g. cleanupAndExit for an unsupported OS) stopped
    /// on purpose and never falls back. Neither do managed labels, which may pin a version.
    static func fallbackOutput(label: String, labelFileURL: URL,
                               result: ZshScriptRunner.ScriptResult,
                               localOutput: [String: Any]?) -> [String: Any]? {
        guard Preferences().labelTrackerFallbackEnabled else { return nil }

        if labelFileURL.path.hasPrefix(AppConstants.managedLabelsFolderURL.path) {
            Logger.log("ℹ️ \(label) is a managed label — Installomator-Tracker fallback not used")
            return nil
        }

        var base: [String: Any]
        if let localOutput {
            let identity = ["name", "type", "expectedTeamID"]
            guard identity.allSatisfy({ !((localOutput[$0] as? String) ?? "").isEmpty }),
                  ((localOutput["downloadURL"] as? String) ?? "").isEmpty else { return nil }
            base = localOutput
        } else if result.timedOut {
            guard let previous = previousScriptOutput(label: label) else {
                Logger.log("ℹ️ \(label) timed out with no earlier scan data — Installomator-Tracker fallback not possible")
                return nil
            }
            // appCustomVersion holds the *installed* version the label's function resolved;
            // a stale copy could misreport what's installed, so don't guess.
            guard ((previous["appCustomVersion"] as? String) ?? "").isEmpty else {
                Logger.log("ℹ️ \(label) timed out and detects its installed version with appCustomVersion — Installomator-Tracker fallback not used")
                return nil
            }
            base = previous
        } else {
            return nil
        }

        guard let entry = resolvedEntry(for: label) else {
            Logger.log("ℹ️ Installomator-Tracker has no resolved values for \(label)")
            return nil
        }

        for key in ["name", "type", "expectedTeamID"] {
            let local = (base[key] as? String) ?? ""
            let tracker: String
            switch key {
            case "name": tracker = entry.name
            case "type": tracker = entry.type
            default:     tracker = entry.expectedTeamID
            }
            guard local == tracker else {
                Logger.log("⚠️ Installomator-Tracker \(key) for \(label) is '\(tracker)', local label has '\(local)' — fallback not used")
                return nil
            }
        }

        var url = entry.downloadURL
        #if arch(x86_64)
        if !entry.downloadURLi386.isEmpty { url = entry.downloadURLi386 }
        #endif

        base["appNewVersion"] = entry.appNewVersion
        base["downloadURL"] = url
        base["timeStamp"] = ISO8601DateFormatter().string(from: Date())
        base["resolvedVia"] = "tracker"
        base["trackerTimeStamp"] = entry.timeStamp

        Logger.log("🛰️ \(label): using Installomator-Tracker values — \(entry.appNewVersion) (\(url))")
        return base
    }

    /// The label's script output as recorded by its last successful run, from the
    /// Discovered plist (installed) or Scanned plist (not installed).
    private static func previousScriptOutput(label: String) -> [String: Any]? {
        for folder in [AppConstants.patcherDiscoveredFolderURL, AppConstants.patcherScannedFolderURL] {
            let url = folder.appendingPathComponent("\(label).plist")
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            var output: [String: Any] = [:]
            for key in scriptOutputKeys {
                guard let value = plist[key] else { return nil }   // older plist missing keys
                output[key] = value
            }
            return output
        }
        return nil
    }

    // MARK: - Loading

    private static func load() -> [String: Entry]? {
        let prefs = Preferences()
        guard prefs.labelTrackerFallbackEnabled else {
            Logger.log("ℹ️ Installomator-Tracker fallback disabled (LabelTrackerFallbackEnabled = false)")
            return nil
        }
        let urlString = prefs.labelTrackerURL
        guard let url = URL(string: urlString), url.scheme?.lowercased() == "https" else {
            Logger.log("⚠️ LabelTrackerURL is not a valid https URL — Installomator-Tracker fallback disabled")
            return nil
        }

        guard let data = download.fetch(url: url) else {
            Logger.log("⚠️ Installomator-Tracker fallback unavailable for this run")
            return nil
        }
        guard let entries = parse(data) else {
            Logger.log("⚠️ Installomator-Tracker data could not be parsed — fallback disabled for this run")
            return nil
        }
        let resolvedCount = entries.values.filter(\.resolved).count
        Logger.log("🛰️ Installomator-Tracker data loaded: \(entries.count) labels, \(resolvedCount) resolved")
        return entries
    }

    /// Accepts either a top-level array of label objects, or
    /// `{"generatedAt": "<ISO 8601>", "labels": [...]}` — in which case data older than
    /// 48 hours is treated as stale (the tracker has stopped updating).
    static func parse(_ data: Data) -> [String: Entry]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }

        let items: [[String: Any]]
        if let array = json as? [[String: Any]] {
            items = array
        } else if let object = json as? [String: Any], let array = object["labels"] as? [[String: Any]] {
            if let generated = object["generatedAt"] as? String,
               let date = ISO8601DateFormatter().date(from: generated),
               Date().timeIntervalSince(date) > maxGeneratedAge {
                Logger.log("⚠️ Installomator-Tracker data was generated \(generated) — too old, fallback not used")
                return [:]
            }
            items = array
        } else {
            return nil
        }

        var entries: [String: Entry] = [:]
        for item in items {
            func string(_ key: String) -> String { (item[key] as? String) ?? "" }
            let label = string("label")
            guard !label.isEmpty else { continue }
            entries[label] = Entry(label: label, name: string("name"), type: string("type"),
                                   expectedTeamID: string("expectedTeamID"),
                                   appNewVersion: string("appNewVersion"),
                                   downloadURL: string("downloadURL"),
                                   downloadURLi386: string("downloadURLi386"),
                                   status: string("status"), timeStamp: string("timeStamp"))
        }
        return entries
    }
}
