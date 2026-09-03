//
//  PendingReporter.swift
//  patcher
//
//  Created by Gil Burns on 4/15/26.
//

import Foundation

// MARK: - Pending Report

struct PendingReporter {
    let format: OutputFormat

    func run(to path: String?) {
        let ctx   = ReportContext()
        let items = buildPendingItems(ctx)
        switch format {
        case .table: emit(buildTable(items, ctx: ctx), to: path)
        case .json:  emit(prettyJSON(jsonObject(ctx)), to: path)
        case .csv:   emit(buildCSV(items, ctx: ctx),   to: path)
        }
    }

    private func prettyJSON(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
                withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func buildTable(_ items: [PendingItem], ctx: ReportContext) -> String {
        let w = 72
        var lines: [String] = []
        lines.append(String(repeating: "═", count: w))
        lines.append(" Pending Updates (staged, not yet applied)  —  \(shortDateTime(ctx.now))")
        lines.append(String(repeating: "═", count: w))
        if items.isEmpty {
            lines.append(" No pending updates.")
        } else {
            lines.append(" \(col("Label", 26))  \(col("Staged Ver.", 12))  \(col("Staged Date", 16))  Days")
            lines.append(String(repeating: "─", count: w))
            for item in items {
                let v = item.stagedVersion.isEmpty ? "(unknown)" : "v\(item.stagedVersion)"
                lines.append(" \(col(item.label, 26))  \(col(v, 12))  \(col(shortDateTime(item.stagedDate), 16))  \(item.daysPending)d")
            }
            lines.append(String(repeating: "─", count: w))
            lines.append(contentsOf: DeadlineSummary(ctx, pendingItems: items).tableLines())
        }
        lines.append(String(repeating: "═", count: w))
        return lines.joined(separator: "\n")
    }

    /// The `pending --json` payload. Also consumed by the `get` subcommand.
    func jsonObject(_ ctx: ReportContext) -> [String: Any] {
        let iso   = ISO8601DateFormatter()
        let items = buildPendingItems(ctx)
        let arr: [[String: Any]] = items.map { item in
            var d: [String: Any] = [
                "label":       item.label,
                "stagedDate":  iso.string(from: item.stagedDate),
                "daysPending": item.daysPending
            ]
            if !item.stagedVersion.isEmpty    { d["stagedVersion"]    = item.stagedVersion }
            if !item.installedVersion.isEmpty { d["installedVersion"] = item.installedVersion }
            return d
        }
        return [
            "generatedAt": iso.string(from: ctx.now),
            "pending":     arr,
            "deadline":    DeadlineSummary(ctx, pendingItems: items).jsonObject(),
        ]
    }

    private func buildCSV(_ items: [PendingItem], ctx: ReportContext) -> String {
        var rows = [csvRow(["label", "stagedVersion", "stagedDate", "installedVersion", "daysPending"])]
        for item in items {
            rows.append(csvRow([
                item.label,
                item.stagedVersion,
                shortDateTime(item.stagedDate),
                item.installedVersion,
                "\(item.daysPending)"
            ]))
        }
        return rows.joined(separator: "\n")
    }
}
