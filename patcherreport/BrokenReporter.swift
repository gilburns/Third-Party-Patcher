//
//  BrokenReporter.swift
//  patcher
//
//  Created by Gil Burns on 4/15/26.
//

import Foundation

// MARK: - Broken Labels Report

struct BrokenReporter {
    let format: OutputFormat

    func run(to path: String?) {
        let ctx = ReportContext()
        switch format {
        case .table: emit(buildTable(ctx), to: path)
        case .json:  emit(buildJSON(ctx),  to: path)
        case .csv:   emit(buildCSV(ctx),   to: path)
        }
    }

    private func buildTable(_ ctx: ReportContext) -> String {
        let w = 62
        var lines: [String] = []
        let scanBroken     = (ctx.config["lastScanBrokenLabels"] as? [String] ?? []).sorted()
        let stageBroken    = (ctx.config["stageBrokenLabels"]    as? [String] ?? []).sorted()
        let failedAttempts =  ctx.config["stageFailedAttempts"]  as? [String: Int] ?? [:]
        let scanVersion    =  ctx.config["lastScanFullInstallomatorVersion"] as? String ?? "unknown"
        let stageVersion   =  ctx.config["stageInstallomatorVersion"]        as? String ?? "unknown"

        lines.append(String(repeating: "═", count: w))
        lines.append(" Broken Labels Report  —  \(shortDateTime(ctx.now))")
        lines.append(String(repeating: "═", count: w))

        lines.append(" Scan-Broken Labels (\(scanBroken.count))  —  Installomator \(scanVersion)")
        lines.append(String(repeating: "─", count: w))
        if scanBroken.isEmpty {
            lines.append("   (none)")
        } else {
            scanBroken.forEach { lines.append("   \($0)") }
        }

        lines.append("")
        lines.append(" Stage-Broken Labels (\(stageBroken.count))  —  Installomator \(stageVersion)")
        lines.append(String(repeating: "─", count: w))
        if stageBroken.isEmpty {
            lines.append("   (none)")
        } else {
            for label in stageBroken {
                let n = failedAttempts[label] ?? 0
                let suffix = n > 0 ? "  (\(n) failed attempt\(n == 1 ? "" : "s"))" : ""
                lines.append("   \(label)\(suffix)")
            }
        }
        lines.append(String(repeating: "═", count: w))
        return lines.joined(separator: "\n")
    }

    private func buildJSON(_ ctx: ReportContext) -> String {
        guard let data = try? JSONSerialization.data(
                withJSONObject: jsonObject(ctx),
                options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// The `broken --json` payload. Also consumed by the `get` subcommand.
    func jsonObject(_ ctx: ReportContext) -> [String: Any] {
        let iso            = ISO8601DateFormatter()
        let scanBroken     = (ctx.config["lastScanBrokenLabels"] as? [String] ?? []).sorted()
        let stageBroken    = (ctx.config["stageBrokenLabels"]    as? [String] ?? []).sorted()
        let failedAttempts =  ctx.config["stageFailedAttempts"]  as? [String: Int] ?? [:]
        let scanVersion    =  ctx.config["lastScanFullInstallomatorVersion"] as? String ?? ""
        let stageVersion   =  ctx.config["stageInstallomatorVersion"]        as? String ?? ""

        let stageArr: [[String: Any]] = stageBroken.map { label in
            var d: [String: Any] = ["label": label]
            if let a = failedAttempts[label] { d["failedAttempts"] = a }
            return d
        }
        return [
            "generatedAt": iso.string(from: ctx.now),
            "scanBroken":  ["installomatorVersion": scanVersion, "labels": scanBroken],
            "stageBroken": ["installomatorVersion": stageVersion, "labels": stageArr]
        ]
    }

    private func buildCSV(_ ctx: ReportContext) -> String {
        let scanBroken     = (ctx.config["lastScanBrokenLabels"] as? [String] ?? []).sorted()
        let stageBroken    = (ctx.config["stageBrokenLabels"]    as? [String] ?? []).sorted()
        let failedAttempts =  ctx.config["stageFailedAttempts"]  as? [String: Int] ?? [:]
        let scanVersion    =  ctx.config["lastScanFullInstallomatorVersion"] as? String ?? ""
        let stageVersion   =  ctx.config["stageInstallomatorVersion"]        as? String ?? ""

        var rows = [csvRow(["category", "label", "installomatorVersion", "failedAttempts"])]
        for label in scanBroken {
            rows.append(csvRow(["scan", label, scanVersion, ""]))
        }
        for label in stageBroken {
            let attempts = failedAttempts[label].map { "\($0)" } ?? ""
            rows.append(csvRow(["stage", label, stageVersion, attempts]))
        }
        return rows.joined(separator: "\n")
    }
}
