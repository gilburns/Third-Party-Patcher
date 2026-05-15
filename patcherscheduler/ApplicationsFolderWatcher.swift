//
//  ApplicationsFolderWatcher.swift
//  patcherscheduler
//
//  Watches /Applications and /Applications/Utilities for newly-added .app bundles.
//  When a new bundle appears, performs a reverse lookup against scanned plists to
//  find a matching Installomator label, then fires the provided callback so the
//  scheduler can run a targeted `patcher lightScan --label <label>` on the work queue.
//
//  Guards against circular triggers from patcher's own apply phase:
//    1. If active_phase.json exists when the debounce fires, the debounce is
//       extended — patcher may still be writing the discovered plist.
//    2. If a discovered plist already exists for the matched label, the app was
//       installed by patcher itself and the callback is suppressed.
//

import Foundation

final class ApplicationsFolderWatcher {

    private let watchedPaths = ["/Applications", "/Applications/Utilities"]

    // Called on the work queue with the matched label name when a new,
    // untracked .app bundle is detected.
    private let onLabelDetected: (String) -> Void

    private var sources: [DispatchSourceFileSystemObject] = []

    // All mutable state below is touched exclusively on debounceQueue (serial).
    private let debounceQueue = DispatchQueue(label: "com.gilburns.patcher.appwatcher", qos: .utility)
    private var snapshot:     Set<String> = []
    private var debounceItem: DispatchWorkItem?
    private let debounceDelay: TimeInterval = 30

    init(onLabelDetected: @escaping (String) -> Void) {
        self.onLabelDetected = onLabelDetected
        // Capture baseline before any watch fires
        debounceQueue.sync { self.snapshot = self.currentAppNames() }
        startWatching()
    }

    deinit {
        sources.forEach { $0.cancel() }
    }

    // MARK: - FSEvent setup

    private func startWatching() {
        for path in watchedPaths {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else {
                Logger.log("⚠️ AppWatcher: cannot open '\(path)' for watching — skipping.")
                continue
            }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: .write,
                queue: debounceQueue
            )
            source.setEventHandler  { [weak self] in self?.scheduleDebounce() }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
        Logger.log("ℹ️ AppWatcher: monitoring \(watchedPaths.joined(separator: " + ")) for new installs.")
    }

    // MARK: - Debounce

    private func scheduleDebounce() {
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.processChange() }
        debounceItem = item
        debounceQueue.asyncAfter(deadline: .now() + debounceDelay, execute: item)
    }

    // MARK: - Change processing (runs on debounceQueue)

    private func processChange() {
        // Guard: if patcher is mid-run, its discovered plist may not be written yet.
        // Extend the debounce so we check after it finishes.
        let activePhaseURL = AppConstants.patcherConfigFolderURL
            .appendingPathComponent("active_phase.json")
        if FileManager.default.fileExists(atPath: activePhaseURL.path) {
            Logger.verbose("ℹ️ AppWatcher: patcher active — deferring check by \(Int(debounceDelay))s.")
            scheduleDebounce()
            return
        }

        let current = currentAppNames()
        let newApps = current.subtracting(snapshot)
        snapshot    = current

        guard !newApps.isEmpty else { return }

        Logger.log("ℹ️ AppWatcher: \(newApps.count) new bundle(s): \(newApps.sorted().joined(separator: ", "))")

        let index = buildScannedIndex()

        for appName in newApps.sorted() {
            guard let label = index[appName] else {
                Logger.log("ℹ️ AppWatcher: '\(appName)' — not in tracked labels.")
                continue
            }

            // Guard: skip if patcher already has a discovered plist for this label.
            // This is the primary protection against circular triggers from patcher's
            // own apply phase — the discovered plist is written before the debounce expires.
            let discoveredURL = AppConstants.patcherDiscoveredFolderURL
                .appendingPathComponent("\(label).plist")
            if FileManager.default.fileExists(atPath: discoveredURL.path) {
                Logger.log("ℹ️ AppWatcher: '\(appName)' → '\(label)' already in Discovered — skipping.")
                continue
            }

            Logger.log("✅ AppWatcher: '\(appName)' → '\(label)' not yet tracked — queuing label scan.")
            onLabelDetected(label)
        }
    }

    // MARK: - Helpers

    /// Returns the set of .app bundle names currently present in the watched paths.
    private func currentAppNames() -> Set<String> {
        var names = Set<String>()
        for path in watchedPaths {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                names.insert(entry)
            }
        }
        return names
    }

    /// Builds a reverse-lookup index from the Scanned folder plists.
    /// Maps "AppName.app" → "label" using the appName and name fields.
    /// Built fresh on each trigger (reading ~900 small plists takes < 1s).
    private func buildScannedIndex() -> [String: String] {
        var index: [String: String] = [:]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: AppConstants.patcherScannedFolderURL, includingPropertiesForKeys: nil
        ).filter({ $0.pathExtension == "plist" }) else { return index }

        for url in urls {
            let label = url.deletingPathExtension().lastPathComponent
            guard let data  = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data, format: nil
                  ) as? [String: Any]
            else { continue }

            let appName = plist["appName"] as? String ?? ""
            let name    = plist["name"]    as? String ?? ""

            if !appName.isEmpty { index[appName] = label }
            if !name.isEmpty    { index["\(name).app"] = label }
        }
        return index
    }
}
