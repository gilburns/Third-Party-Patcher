//
//  SummaryReporter.swift
//  patcher
//
//  Created by Gil Burns on 4/15/26.
//

import Foundation

// MARK: - Summary Report

struct SummaryReporter {
    let format: OutputFormat

    func run(to path: String?) {
        let ctx = ReportContext()
        switch format {
        case .table: emit(buildTable(ctx), to: path)
        case .json:  emit(buildJSON(ctx),  to: path)
        case .csv:   emit(buildCSV(ctx),   to: path)
        }
    }

    private func statusCounts(_ ctx: ReportContext) -> [String: Int] {
        var counts: [String: Int] = [:]
        for (_, plist) in ctx.discoveredPlists {
            let s = plist["updateStatus"] as? String ?? "unknown"
            counts[s, default: 0] += 1
        }
        return counts
    }

    private func buildTable(_ ctx: ReportContext) -> String {
        let w = 62
        var lines: [String] = []
        let sc = statusCounts(ctx)

        lines.append(String(repeating: "═", count: w))
        lines.append(" Patcher Summary Report  —  \(shortDateTime(ctx.now))")
        lines.append(String(repeating: "═", count: w))

        func stat(_ label: String, _ value: Int) -> String {
            " \(col(label, 34)) \(value)"
        }

        lines.append(stat("Discovered labels:",        ctx.discoveredPlists.count))
        lines.append(stat("  Up to date:",             sc["upToDate"]      ?? 0))
        lines.append(stat("  Update required:",        sc["updateRequired"] ?? 0))
        lines.append(stat("  Unknown status:",         sc["unknown"]        ?? 0))
        lines.append(stat("  Would downgrade:",        sc["wouldDowngrade"] ?? 0))
        lines.append(String(repeating: "─", count: w))

        let everApplied = ctx.histories.filter {
            $0.history.events.contains { $0.type == LabelHistoryEvent.EventType.applied }
        }.count
        let neverUpdated = ctx.histories.filter {
            !$0.history.events.contains { $0.type == LabelHistoryEvent.EventType.applied }
        }.count

        lines.append(stat("Labels ever applied:",      everApplied))
        lines.append(stat("Labels pending (staged):",  buildPendingItems(ctx).count))
        lines.append(stat("Labels never updated:",     neverUpdated))
        lines.append(String(repeating: "─", count: w))

        let scanBroken  = ctx.config["lastScanBrokenLabels"] as? [String] ?? []
        let stageBroken = ctx.config["stageBrokenLabels"]    as? [String] ?? []
        lines.append(stat("Scan-broken labels:",       scanBroken.count))
        lines.append(stat("Stage-broken labels:",      stageBroken.count))
        lines.append(String(repeating: "─", count: w))

        func runLine(_ label: String, startKey: String, countKey: String, countNoun: String) -> String {
            if let date = ctx.configDate(startKey) {
                let n = ctx.config[countKey] as? Int ?? 0
                return " \(col(label, 15)) \(shortDateTime(date))  (\(n) \(countNoun))"
            }
            return " \(col(label, 15)) never"
        }
        lines.append(runLine("Last scan:",  startKey: "lastScanFullStart", countKey: "lastScanFullLabelCount", countNoun: "labels"))
        lines.append(runLine("Last check:", startKey: "lastCheckStart",    countKey: "lastCheckLabelCount",    countNoun: "checked"))
        lines.append(runLine("Last stage:", startKey: "lastStageStart",    countKey: "lastStagedCount",        countNoun: "staged"))
        lines.append(runLine("Last apply:", startKey: "lastApplyStart",    countKey: "lastApplyCount",         countNoun: "applied"))
        lines.append(String(repeating: "═", count: w))

        return lines.joined(separator: "\n")
    }

    private func buildJSON(_ ctx: ReportContext) -> String {
        let iso = ISO8601DateFormatter()
        let sc = statusCounts(ctx)
        let everApplied = ctx.histories.filter {
            $0.history.events.contains { $0.type == LabelHistoryEvent.EventType.applied }
        }.count

        var d: [String: Any] = [
            "generatedAt":        iso.string(from: ctx.now),
            "totalDiscovered":    ctx.discoveredPlists.count,
            "upToDate":           sc["upToDate"]      ?? 0,
            "updateRequired":     sc["updateRequired"] ?? 0,
            "unknownStatus":      sc["unknown"]        ?? 0,
            "wouldDowngrade":     sc["wouldDowngrade"] ?? 0,
            "labelsEverApplied":  everApplied,
            "labelsPending":      buildPendingItems(ctx).count,
            "labelsNeverUpdated": ctx.histories.count - everApplied,
            "scanBrokenCount":    (ctx.config["lastScanBrokenLabels"] as? [String] ?? []).count,
            "stageBrokenCount":   (ctx.config["stageBrokenLabels"]    as? [String] ?? []).count,
        ]

        func addRun(_ outKey: String, startKey: String, countKey: String) {
            var r: [String: Any] = [:]
            if let date = ctx.configDate(startKey)           { r["lastRun"] = iso.string(from: date) }
            if let n    = ctx.config[countKey] as? Int       { r["count"]   = n }
            d[outKey] = r
        }
        addRun("lastScan",   startKey: "lastScanFullStart", countKey: "lastScanFullLabelCount")
        addRun("lastCheck",  startKey: "lastCheckStart",    countKey: "lastCheckLabelCount")
        addRun("lastStage",  startKey: "lastStageStart",    countKey: "lastStagedCount")
        addRun("lastApply",  startKey: "lastApplyStart",    countKey: "lastApplyCount")

        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func buildCSV(_ ctx: ReportContext) -> String {
        let sc = statusCounts(ctx)
        let everApplied = ctx.histories.filter {
            $0.history.events.contains { $0.type == LabelHistoryEvent.EventType.applied }
        }.count
        let rows: [[String]] = [
            ["metric", "value"],
            ["totalDiscovered",    "\(ctx.discoveredPlists.count)"],
            ["upToDate",           "\(sc["upToDate"]      ?? 0)"],
            ["updateRequired",     "\(sc["updateRequired"] ?? 0)"],
            ["unknownStatus",      "\(sc["unknown"]        ?? 0)"],
            ["wouldDowngrade",     "\(sc["wouldDowngrade"] ?? 0)"],
            ["labelsEverApplied",  "\(everApplied)"],
            ["labelsPending",      "\(buildPendingItems(ctx).count)"],
            ["labelsNeverUpdated", "\(ctx.histories.count - everApplied)"],
            ["scanBrokenCount",    "\((ctx.config["lastScanBrokenLabels"] as? [String] ?? []).count)"],
            ["stageBrokenCount",   "\((ctx.config["stageBrokenLabels"]    as? [String] ?? []).count)"],
        ]
        return rows.map(csvRow).joined(separator: "\n")
    }
}
