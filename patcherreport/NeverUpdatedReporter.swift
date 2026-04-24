//
//  NeverUpdatedReporter.swift
//  patcher
//
//  Created by Gil Burns on 4/15/26.
//

import Foundation

// MARK: - Never-Updated Report

struct NeverUpdatedReporter {
    let format: OutputFormat

    func run(to path: String?) {
        let ctx   = ReportContext()
        let items = ctx.histories
            .filter { !$0.history.events.contains { $0.type == LabelHistoryEvent.EventType.applied } }
            .sorted { $0.history.firstDiscoveredDate < $1.history.firstDiscoveredDate }
        switch format {
        case .table: emit(buildTable(items, ctx: ctx), to: path)
        case .json:  emit(buildJSON(items,  ctx: ctx), to: path)
        case .csv:   emit(buildCSV(items,   ctx: ctx), to: path)
        }
    }

    private func buildTable(_ items: [(label: String, history: LabelHistory)], ctx: ReportContext) -> String {
        let w = 72
        var lines: [String] = []
        lines.append(String(repeating: "═", count: w))
        lines.append(" Never-Updated Labels (\(items.count))  —  \(shortDateTime(ctx.now))")
        lines.append(String(repeating: "═", count: w))
        if items.isEmpty {
            lines.append(" All tracked labels have been updated at least once.")
        } else {
            lines.append(" \(col("Label", 28))  \(col("Discovered", 10))  \(col("Version", 12))  Status")
            lines.append(String(repeating: "─", count: w))
            for item in items {
                let status = ctx.discoveredPlists[item.label]?["updateStatus"] as? String ?? ""
                lines.append(" \(col(item.label, 28))  \(col(shortDate(item.history.firstDiscoveredDate), 10))  \(col(item.history.firstDiscoveredVersion, 12))  \(status)")
            }
        }
        lines.append(String(repeating: "═", count: w))
        return lines.joined(separator: "\n")
    }

    private func buildJSON(_ items: [(label: String, history: LabelHistory)], ctx: ReportContext) -> String {
        let iso = ISO8601DateFormatter()
        let arr: [[String: Any]] = items.map { item in
            [
                "label":                  item.label,
                "firstDiscoveredDate":    iso.string(from: item.history.firstDiscoveredDate),
                "firstDiscoveredVersion": item.history.firstDiscoveredVersion,
                "currentStatus":          ctx.discoveredPlists[item.label]?["updateStatus"] as? String ?? ""
            ]
        }
        let out: [String: Any] = ["generatedAt": iso.string(from: ctx.now), "neverUpdated": arr]
        guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func buildCSV(_ items: [(label: String, history: LabelHistory)], ctx: ReportContext) -> String {
        var rows = [csvRow(["label", "firstDiscoveredDate", "firstDiscoveredVersion", "currentStatus"])]
        for item in items {
            rows.append(csvRow([
                item.label,
                shortDate(item.history.firstDiscoveredDate),
                item.history.firstDiscoveredVersion,
                ctx.discoveredPlists[item.label]?["updateStatus"] as? String ?? ""
            ]))
        }
        return rows.joined(separator: "\n")
    }
}
