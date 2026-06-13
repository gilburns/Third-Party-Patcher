//
//  LabelHistory.swift
//  patcher
//
//  Created by Gil Burns on 4/11/26.
//
//  Tracks per-label patching history in a history.json file inside each label's
//  cache folder:  .../Patcher/Cache/<label>/history.json
//
//  Event types recorded:
//    discovered   — app first found installed on this device
//    updateFound  — a newer version was detected (scan or check)
//    staged       — update downloaded successfully (includes file size)
//    applied      — update installed successfully
//

import Foundation

// MARK: - Event

struct LabelHistoryEvent: Codable {
    let type: String          // see EventType constants below
    let date: Date
    let installedVersion: String?    // discovered, updateFound
    let availableVersion: String?    // updateFound, staged, applied
    let downloadURL: String?         // staged
    let fileSizeBytes: Int64?        // staged
    let fromVersion: String?         // applied
    let toVersion: String?           // applied
    let deferralMinutes: Int?        // userDeferred, timedOutDeferred
    let blockingProcessName: String? // blockingProcess* events

    // MARK: Factories

    static func discovered(date: Date, installedVersion: String) -> LabelHistoryEvent {
        LabelHistoryEvent(type: EventType.discovered,
                          date: date,
                          installedVersion: installedVersion,
                          availableVersion: nil,
                          downloadURL: nil,
                          fileSizeBytes: nil,
                          fromVersion: nil,
                          toVersion: nil,
                          deferralMinutes: nil,
                          blockingProcessName: nil)
    }

    static func updateFound(date: Date,
                            installedVersion: String,
                            availableVersion: String) -> LabelHistoryEvent {
        LabelHistoryEvent(type: EventType.updateFound,
                          date: date,
                          installedVersion: installedVersion,
                          availableVersion: availableVersion,
                          downloadURL: nil,
                          fileSizeBytes: nil,
                          fromVersion: nil,
                          toVersion: nil,
                          deferralMinutes: nil,
                          blockingProcessName: nil)
    }

    static func staged(date: Date,
                       availableVersion: String,
                       downloadURL: String,
                       fileSizeBytes: Int64?) -> LabelHistoryEvent {
        LabelHistoryEvent(type: EventType.staged,
                          date: date,
                          installedVersion: nil,
                          availableVersion: availableVersion,
                          downloadURL: downloadURL,
                          fileSizeBytes: fileSizeBytes,
                          fromVersion: nil,
                          toVersion: nil,
                          deferralMinutes: nil,
                          blockingProcessName: nil)
    }

    static func applied(date: Date,
                        fromVersion: String,
                        toVersion: String) -> LabelHistoryEvent {
        LabelHistoryEvent(type: EventType.applied,
                          date: date,
                          installedVersion: nil,
                          availableVersion: nil,
                          downloadURL: nil,
                          fileSizeBytes: nil,
                          fromVersion: fromVersion,
                          toVersion: toVersion,
                          deferralMinutes: nil,
                          blockingProcessName: nil)
    }

    // MARK: Dialog interaction factories

    static func userContinued(date: Date) -> LabelHistoryEvent {
        LabelHistoryEvent(type: EventType.userContinued, date: date,
                          installedVersion: nil, availableVersion: nil,
                          downloadURL: nil, fileSizeBytes: nil,
                          fromVersion: nil, toVersion: nil,
                          deferralMinutes: nil, blockingProcessName: nil)
    }

    static func userDeferred(date: Date, minutes: Int) -> LabelHistoryEvent {
        LabelHistoryEvent(type: EventType.userDeferred, date: date,
                          installedVersion: nil, availableVersion: nil,
                          downloadURL: nil, fileSizeBytes: nil,
                          fromVersion: nil, toVersion: nil,
                          deferralMinutes: minutes, blockingProcessName: nil)
    }

    static func timedOutDeferred(date: Date, minutes: Int) -> LabelHistoryEvent {
        LabelHistoryEvent(type: EventType.timedOutDeferred, date: date,
                          installedVersion: nil, availableVersion: nil,
                          downloadURL: nil, fileSizeBytes: nil,
                          fromVersion: nil, toVersion: nil,
                          deferralMinutes: minutes, blockingProcessName: nil)
    }

    static func deadlineForced(date: Date) -> LabelHistoryEvent {
        LabelHistoryEvent(type: EventType.deadlineForced, date: date,
                          installedVersion: nil, availableVersion: nil,
                          downloadURL: nil, fileSizeBytes: nil,
                          fromVersion: nil, toVersion: nil,
                          deferralMinutes: nil, blockingProcessName: nil)
    }

    static func blockingProcessNotified(date: Date, processName: String) -> LabelHistoryEvent {
        LabelHistoryEvent(type: EventType.blockingProcessNotified, date: date,
                          installedVersion: nil, availableVersion: nil,
                          downloadURL: nil, fileSizeBytes: nil,
                          fromVersion: nil, toVersion: nil,
                          deferralMinutes: nil, blockingProcessName: processName)
    }

    static func blockingProcessSkipped(date: Date, processName: String) -> LabelHistoryEvent {
        LabelHistoryEvent(type: EventType.blockingProcessSkipped, date: date,
                          installedVersion: nil, availableVersion: nil,
                          downloadURL: nil, fileSizeBytes: nil,
                          fromVersion: nil, toVersion: nil,
                          deferralMinutes: nil, blockingProcessName: processName)
    }

    static func blockingProcessTimedOut(date: Date, processName: String) -> LabelHistoryEvent {
        LabelHistoryEvent(type: EventType.blockingProcessTimedOut, date: date,
                          installedVersion: nil, availableVersion: nil,
                          downloadURL: nil, fileSizeBytes: nil,
                          fromVersion: nil, toVersion: nil,
                          deferralMinutes: nil, blockingProcessName: processName)
    }

    static func blockingProcessQuit(date: Date, processName: String) -> LabelHistoryEvent {
        LabelHistoryEvent(type: EventType.blockingProcessQuit, date: date,
                          installedVersion: nil, availableVersion: nil,
                          downloadURL: nil, fileSizeBytes: nil,
                          fromVersion: nil, toVersion: nil,
                          deferralMinutes: nil, blockingProcessName: processName)
    }

    static func selfServiceInstall(date: Date) -> LabelHistoryEvent {
        LabelHistoryEvent(type: EventType.selfServiceInstall, date: date,
                          installedVersion: nil, availableVersion: nil,
                          downloadURL: nil, fileSizeBytes: nil,
                          fromVersion: nil, toVersion: nil,
                          deferralMinutes: nil, blockingProcessName: nil)
    }

    enum EventType {
        static let discovered  = "discovered"
        static let updateFound = "updateFound"
        static let staged      = "staged"
        static let applied     = "applied"
        // User-initiated self-service install via App Catalog
        static let selfServiceInstall = "selfServiceInstall"
        // Dialog interaction outcomes
        static let userContinued           = "userContinued"
        static let userDeferred            = "userDeferred"
        static let timedOutDeferred        = "timedOutDeferred"
        static let deadlineForced          = "deadlineForced"
        static let blockingProcessNotified = "blockingProcessNotified"
        static let blockingProcessSkipped  = "blockingProcessSkipped"
        static let blockingProcessTimedOut = "blockingProcessTimedOut"
        static let blockingProcessQuit     = "blockingProcessQuit"
    }
}

// MARK: - History

struct LabelHistory: Codable {
    var firstDiscoveredDate: Date
    var firstDiscoveredVersion: String
    var events: [LabelHistoryEvent]

    // MARK: File location

    static func url(for label: String) -> URL {
        AppConstants.patcherCacheFolderURL
            .appendingPathComponent(label)
            .appendingPathComponent("history.json")
    }

    static let fileName = "history.json"

    // MARK: Persistence

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .prettyPrinted
        return e
    }

    static func load(label: String) -> LabelHistory? {
        guard let data = try? Data(contentsOf: url(for: label)) else { return nil }
        return try? decoder().decode(LabelHistory.self, from: data)
    }

    func save(label: String) {
        guard let data = try? LabelHistory.encoder().encode(self) else {
            Logger.log("❌ LabelHistory: failed to encode history for \(label)")
            return
        }
        let url = LabelHistory.url(for: label)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            Logger.log("❌ LabelHistory: failed to save history for \(label): \(error)")
        }
    }

    // MARK: Mutation helpers

    /// Appends an event and saves. Creates the history file if this is the first event.
    static func append(event: LabelHistoryEvent, label: String) {
        var history: LabelHistory
        if var existing = load(label: label) {
            existing.events.append(event)
            history = existing
        } else {
            // Shouldn't normally happen — history should be created at discovery.
            // Defensive fallback: seed from this event.
            history = LabelHistory(
                firstDiscoveredDate: event.date,
                firstDiscoveredVersion: event.installedVersion ?? event.fromVersion ?? "",
                events: [event]
            )
        }
        history.save(label: label)
    }

    /// Returns the most recent event of the given type, or nil.
    func lastEvent(ofType type: String) -> LabelHistoryEvent? {
        events.last(where: { $0.type == type })
    }
}

// MARK: - Recording helpers (called from main.swift)

/// Records a "discovered" event the first time a label is seen installed on this device.
/// Safe to call on every scan/check — does nothing if history already exists.
func recordDiscoveredIfNeeded(label: String, installedVersion: String, date: Date) {
    guard LabelHistory.load(label: label) == nil else { return }

    let event   = LabelHistoryEvent.discovered(date: date, installedVersion: installedVersion)
    let history = LabelHistory(firstDiscoveredDate: date,
                               firstDiscoveredVersion: installedVersion,
                               events: [event])
    history.save(label: label)
    Logger.verbose("📖 History: first discovery recorded for \(label) v\(installedVersion)")
}

/// Records an "updateFound" event when a newer version is detected.
/// Deduplicates: skips if the last updateFound event already has this availableVersion.
func recordUpdateFoundIfNeeded(label: String,
                               installedVersion: String,
                               availableVersion: String,
                               date: Date) {
    guard !availableVersion.isEmpty else { return }
    let history = LabelHistory.load(label: label)
    if let last = history?.lastEvent(ofType: LabelHistoryEvent.EventType.updateFound),
       last.availableVersion == availableVersion {
        return   // already recorded this pending version
    }
    LabelHistory.append(
        event: .updateFound(date: date, installedVersion: installedVersion, availableVersion: availableVersion),
        label: label
    )
    Logger.verbose("📖 History: updateFound recorded for \(label) (\(installedVersion) → \(availableVersion))")
}

/// Records a "staged" event with the file size of the downloaded installer.
func recordStaged(label: String, availableVersion: String, downloadURL: String,
                  stagedFilePath: String, date: Date) {
    let size = (try? FileManager.default.attributesOfItem(atPath: stagedFilePath))?[.size] as? Int64
    LabelHistory.append(
        event: .staged(date: date, availableVersion: availableVersion,
                       downloadURL: downloadURL, fileSizeBytes: size),
        label: label
    )
    let sizeStr = size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "unknown size"
    Logger.verbose("📖 History: staged recorded for \(label) v\(availableVersion) (\(sizeStr))")
}

/// Records an "applied" event after a successful installation.
func recordApplied(label: String, fromVersion: String, toVersion: String, date: Date) {
    LabelHistory.append(
        event: .applied(date: date, fromVersion: fromVersion, toVersion: toVersion),
        label: label
    )
    Logger.log("📖 History: applied \(label) \(fromVersion) → \(toVersion)")
}

/// Records a "selfServiceInstall" event when the user initiates an install via the App Catalog.
/// Written by patcherscheduler (not the patcher binary) so it captures user intent even when
/// the label is brand-new and has no history file yet.
func recordSelfServiceInstall(label: String, date: Date) {
    LabelHistory.append(event: .selfServiceInstall(date: date), label: label)
    Logger.log("📖 History: selfServiceInstall recorded for \(label)")
}

/// Records a blocking-process dialog outcome for a single label.
/// Call this from SwiftDialogController after the user responds to the blocking-process prompt.
func recordBlockingProcessEvent(label: String, type: String, processName: String, date: Date) {
    let event: LabelHistoryEvent
    switch type {
    case LabelHistoryEvent.EventType.blockingProcessNotified:
        event = .blockingProcessNotified(date: date, processName: processName)
    case LabelHistoryEvent.EventType.blockingProcessSkipped:
        event = .blockingProcessSkipped(date: date, processName: processName)
    case LabelHistoryEvent.EventType.blockingProcessTimedOut:
        event = .blockingProcessTimedOut(date: date, processName: processName)
    default:
        event = .blockingProcessQuit(date: date, processName: processName)
    }
    LabelHistory.append(event: event, label: label)
    Logger.verbose("📖 History: blocking process '\(type)' recorded for \(label) (process: \(processName))")
}
