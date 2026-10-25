//
//  DelayedReporter.swift
//  patcherreport
//
//  patcherreport delayed — updates held back by UpdateDelayDays / UpdateDelayOverrides,
//  with the date each becomes eligible to stage and apply.
//

import Foundation

// MARK: - Delayed Report

struct DelayedReporter {
    let format: OutputFormat

    func run(to path: String?) {
        let ctx   = ReportContext()
        let items = buildDelayedItems(ctx)
        switch format {
        case .table: emit(buildTable(items, ctx: ctx), to: path)
        case .json:  emit(prettyJSON(jsonObject(ctx)), to: path)
        case .csv:   emit(buildCSV(items),             to: path)
        }
    }

    private func prettyJSON(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
                withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func buildTable(_ items: [DelayedItem], ctx: ReportContext) -> String {
        let w = 80
        var lines: [String] = []
        lines.append(String(repeating: "═", count: w))
        lines.append(" Delayed Updates (held by update delay)  —  \(shortDateTime(ctx.now))")
        lines.append(String(repeating: "═", count: w))
        if items.isEmpty {
            lines.append(" No delayed updates.")
        } else {
            lines.append(" \(col("Label", 24))  \(col("Installed", 12))  \(col("Available", 12))  \(col("Eligible", 16))  Left")
            lines.append(String(repeating: "─", count: w))
            for item in items {
                let eligible = item.eligibleDate.map(shortDateTime) ?? "(unknown)"
                let left     = item.eligibleDate == nil ? "" : "\(item.daysRemaining)d"
                lines.append(" \(col(item.label, 24))  \(col(item.installedVersion, 12))  \(col(item.availableVersion, 12))  \(col(eligible, 16))  \(left)")
            }
        }
        lines.append(String(repeating: "═", count: w))
        return lines.joined(separator: "\n")
    }

    /// The `delayed --json` payload. Also consumed by the `get` subcommand.
    func jsonObject(_ ctx: ReportContext) -> [String: Any] {
        let iso   = ISO8601DateFormatter()
        let items = buildDelayedItems(ctx)
        let arr: [[String: Any]] = items.map { item in
            var d: [String: Any] = [
                "label":            item.label,
                "installedVersion": item.installedVersion,
                "availableVersion": item.availableVersion,
            ]
            if let date = item.versionFirstSeen {
                d["versionFirstSeen"] = iso.string(from: date)
            }
            if let date = item.eligibleDate {
                d["eligibleDate"]  = iso.string(from: date)
                d["daysRemaining"] = item.daysRemaining
            }
            return d
        }
        return [
            "generatedAt":   iso.string(from: ctx.now),
            "delayed":       arr,
            "labelsDelayed": arr.count,
        ]
    }

    private func buildCSV(_ items: [DelayedItem]) -> String {
        var rows = [csvRow(["label", "installedVersion", "availableVersion", "versionFirstSeen", "eligibleDate", "daysRemaining"])]
        for item in items {
            rows.append(csvRow([
                item.label,
                item.installedVersion,
                item.availableVersion,
                item.versionFirstSeen.map(shortDateTime) ?? "",
                item.eligibleDate.map(shortDateTime) ?? "",
                item.eligibleDate == nil ? "" : "\(item.daysRemaining)"
            ]))
        }
        return rows.joined(separator: "\n")
    }
}


// MARK: - Delayed labels (shared by Summary, Delayed and LabelDetail reporters)

struct DelayedItem {
    let label:            String
    let installedVersion: String
    let availableVersion: String
    /// Earliest sighting of `availableVersion` while `installedVersion` was installed.
    let versionFirstSeen: Date?
    /// Written by the check that delayed the update. nil only for a malformed plist.
    let eligibleDate:     Date?
    /// Whole days until `eligibleDate`, rounded up (0 once it has passed).
    let daysRemaining:    Int
}

func buildDelayedItems(_ ctx: ReportContext) -> [DelayedItem] {
    let histories = Dictionary(ctx.histories.map { ($0.label, $0.history) }, uniquingKeysWith: { a, _ in a })
    let items = ctx.discoveredPlists.compactMap { label, plist -> DelayedItem? in
        delayedItem(label: label, plist: plist, history: histories[label], now: ctx.now)
    }
    return items.sorted { ($0.eligibleDate ?? .distantFuture) < ($1.eligibleDate ?? .distantFuture) }
}

/// The delay state of one label, or nil when its discovered plist isn't "delayed".
func delayedItem(label: String, plist: [String: Any], history: LabelHistory?, now: Date) -> DelayedItem? {
    guard plist["updateStatus"] as? String == "delayed" else { return nil }
    let installed = plist["installedVersion"] as? String ?? ""
    let available = plist["appNewVersion"]    as? String ?? ""
    let eligible  = plist["delayEligibleDate"] as? Date
    let firstSeen = history?.events
        .filter { $0.type == LabelHistoryEvent.EventType.updateFound
                  && $0.installedVersion == installed && $0.availableVersion == available }
        .map(\.date).min()
    let remaining = eligible.map { max(0, Int(($0.timeIntervalSince(now) / 86_400).rounded(.up))) } ?? 0
    return DelayedItem(label: label, installedVersion: installed, availableVersion: available,
                       versionFirstSeen: firstSeen, eligibleDate: eligible, daysRemaining: remaining)
}

