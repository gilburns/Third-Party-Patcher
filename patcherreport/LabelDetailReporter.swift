//
//  LabelDetailReporter.swift
//  patcher
//
//  Created by Gil Burns on 4/15/26.
//

import Foundation

// MARK: - Label Detail Report

struct LabelDetailReporter {
    let label:  String
    let format: OutputFormat

    func run(to path: String?) {
        guard let history = LabelHistory.load(label: label) else {
            fputs("patcherreport: no history found for label '\(label)'\n", stderr)
            exit(1)
        }
        switch format {
        case .table: emit(buildTable(history), to: path)
        case .json:  emit(buildJSON(history),  to: path)
        case .csv:   emit(buildCSV(history),   to: path)
        }
    }

    private func buildTable(_ h: LabelHistory) -> String {
        let w = 80
        var lines: [String] = []
        lines.append(String(repeating: "═", count: w))
        lines.append(" History: \(label)")
        lines.append(" First discovered: \(shortDate(h.firstDiscoveredDate))  v\(h.firstDiscoveredVersion)")
        lines.append(" Total events: \(h.events.count)")
        if let delay = delayState(h) {
            let eligible = delay.eligibleDate.map { "eligible \(shortDateTime($0)) (\(delay.daysRemaining)d)" } ?? "eligible date unknown"
            lines.append(" Delayed: \(delay.installedVersion) → \(delay.availableVersion), \(eligible)")
        }
        lines.append(String(repeating: "═", count: w))
        lines.append(" \(col("Date", 16))  \(col("Event", 23))  Details")
        lines.append(String(repeating: "─", count: w))
        for event in h.events {
            let detail = labelEventDetail(event)
            lines.append(" \(col(shortDateTime(event.date), 16))  \(col(event.type, 23))  \(detail)")
        }
        lines.append(String(repeating: "═", count: w))
        return lines.joined(separator: "\n")
    }

    private func buildJSON(_ h: LabelHistory) -> String {
        let iso = ISO8601DateFormatter()
        let events: [[String: Any]] = h.events.map { event in
            var d: [String: Any] = ["type": event.type, "date": iso.string(from: event.date)]
            if let v = event.installedVersion  { d["installedVersion"]  = v }
            if let v = event.availableVersion  { d["availableVersion"]  = v }
            if let v = event.fromVersion       { d["fromVersion"]       = v }
            if let v = event.toVersion         { d["toVersion"]         = v }
            if let v = event.downloadURL       { d["downloadURL"]       = v }
            if let v = event.fileSizeBytes     { d["fileSizeBytes"]     = v }
            if let v = event.deferralMinutes   { d["deferralMinutes"]   = v }
            if let v = event.blockingProcessName { d["blockingProcessName"] = v }
            return d
        }
        var out: [String: Any] = [
            "label":                  label,
            "firstDiscoveredDate":    iso.string(from: h.firstDiscoveredDate),
            "firstDiscoveredVersion": h.firstDiscoveredVersion,
            "events":                 events
        ]
        if let delay = delayState(h) {
            var d: [String: Any] = ["availableVersion": delay.availableVersion]
            if let date = delay.versionFirstSeen { d["versionFirstSeen"] = iso.string(from: date) }
            if let date = delay.eligibleDate {
                d["eligibleDate"]  = iso.string(from: date)
                d["daysRemaining"] = delay.daysRemaining
            }
            out["delayed"] = d
        }
        guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// The label's current update-delay hold, read from its discovered plist.
    private func delayState(_ h: LabelHistory) -> DelayedItem? {
        let url = AppConstants.patcherDiscoveredFolderURL.appendingPathComponent("\(label).plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return delayedItem(label: label, plist: plist, history: h, now: Date())
    }

    private func buildCSV(_ h: LabelHistory) -> String {
        var rows = [csvRow(["date", "eventType", "installedVersion", "availableVersion",
                            "fromVersion", "toVersion", "downloadURL", "fileSizeBytes",
                            "deferralMinutes", "blockingProcessName"])]
        for event in h.events {
            rows.append(csvRow([
                shortDateTime(event.date),
                event.type,
                event.installedVersion   ?? "",
                event.availableVersion   ?? "",
                event.fromVersion        ?? "",
                event.toVersion          ?? "",
                event.downloadURL        ?? "",
                event.fileSizeBytes.map    { "\($0)" } ?? "",
                event.deferralMinutes.map  { "\($0)" } ?? "",
                event.blockingProcessName  ?? ""
            ]))
        }
        return rows.joined(separator: "\n")
    }
}


// MARK: - Detail helpers (also used by DeferralsReporter)

func labelEventDetail(_ event: LabelHistoryEvent) -> String {
    switch event.type {
    case LabelHistoryEvent.EventType.applied:
        return "\(event.fromVersion ?? "") → \(event.toVersion ?? "")"
    case LabelHistoryEvent.EventType.staged:
        var parts: [String] = []
        if let v = event.availableVersion, !v.isEmpty { parts.append("v\(v)") }
        else { parts.append("(version unknown)") }
        if let sz = event.fileSizeBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: sz, countStyle: .file))
        }
        if let url = event.downloadURL { parts.append("  \(url)") }
        return parts.joined(separator: "  ")
    case LabelHistoryEvent.EventType.updateFound:
        return "\(event.installedVersion ?? "") → \(event.availableVersion ?? "")"
    case LabelHistoryEvent.EventType.discovered:
        return "installed v\(event.installedVersion ?? "")"
    case LabelHistoryEvent.EventType.userContinued:
        return "user clicked Continue"
    case LabelHistoryEvent.EventType.userDeferred:
        return event.deferralMinutes.map { "deferred \(formatMinutes($0))" } ?? ""
    case LabelHistoryEvent.EventType.timedOutDeferred:
        return event.deferralMinutes.map { "auto-deferred \(formatMinutes($0)) (timer expired)" } ?? ""
    case LabelHistoryEvent.EventType.deadlineForced:
        return "proceeded — hard deadline reached"
    case LabelHistoryEvent.EventType.blockingProcessNotified:
        return "notification shown — \(event.blockingProcessName ?? "")"
    case LabelHistoryEvent.EventType.blockingProcessSkipped:
        return "user clicked Skip Update — \(event.blockingProcessName ?? "")"
    case LabelHistoryEvent.EventType.blockingProcessTimedOut:
        return "timer expired, process killed — \(event.blockingProcessName ?? "")"
    case LabelHistoryEvent.EventType.blockingProcessQuit:
        return "user clicked Quit App — \(event.blockingProcessName ?? "")"
    case LabelHistoryEvent.EventType.blockingProcessScreenLocked:
        return "skipped, screen locked — \(event.blockingProcessName ?? "")"
    default:
        return ""
    }
}
