//
//  RecentReporter.swift
//  patcher
//
//  Created by Gil Burns on 4/15/26.
//

import Foundation

// MARK: - Recent Report

struct RecentReporter {
    let days:   Int
    let format: OutputFormat

    struct RecentEvent {
        let label:    String
        let type:     String
        let date:     Date
        let from:     String   // installedVersion or fromVersion
        let to:       String   // availableVersion or toVersion
        let sizeStr:  String
    }

    func run(to path: String?) {
        let ctx    = ReportContext()
        let cutoff = ctx.now.addingTimeInterval(-TimeInterval(days * 86400))
        var events: [RecentEvent] = []

        for (label, history) in ctx.histories {
            for event in history.events {
                guard event.date >= cutoff else { continue }
                // Skip low-signal 'discovered' events from the default recent view
                // unless the label has no other recent events
                let sizeStr = event.fileSizeBytes.map {
                    ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                } ?? ""
                events.append(RecentEvent(
                    label:   label,
                    type:    event.type,
                    date:    event.date,
                    from:    event.fromVersion    ?? event.installedVersion ?? "",
                    to:      event.toVersion      ?? event.availableVersion ?? "",
                    sizeStr: sizeStr
                ))
            }
        }
        events.sort { $0.date > $1.date }

        switch format {
        case .table: emit(buildTable(events, ctx: ctx), to: path)
        case .json:  emit(buildJSON(events,  ctx: ctx), to: path)
        case .csv:   emit(buildCSV(events),             to: path)
        }
    }

    private func eventDetail(_ e: RecentEvent) -> String {
        switch e.type {
        case LabelHistoryEvent.EventType.applied:
            return "\(e.from) → \(e.to)"
        case LabelHistoryEvent.EventType.staged:
            let v = e.to.isEmpty ? "(version unknown)" : "v\(e.to)"
            return e.sizeStr.isEmpty ? v : "\(v)  \(e.sizeStr)"
        case LabelHistoryEvent.EventType.updateFound:
            return "\(e.from) → \(e.to)"
        case LabelHistoryEvent.EventType.discovered:
            return "v\(e.from)"
        default:
            return ""
        }
    }

    private func buildTable(_ events: [RecentEvent], ctx: ReportContext) -> String {
        let w = 78
        var lines: [String] = []
        lines.append(String(repeating: "═", count: w))
        lines.append(" Recent Activity  —  last \(days) day(s)  —  \(shortDateTime(ctx.now))")
        lines.append(String(repeating: "═", count: w))
        if events.isEmpty {
            lines.append(" No events recorded in the last \(days) day(s).")
        } else {
            lines.append(" \(col("Label", 24))  \(col("Event", 13))  \(col("Date", 16))  Details")
            lines.append(String(repeating: "─", count: w))
            for e in events {
                lines.append(" \(col(e.label, 24))  \(col(e.type, 13))  \(col(shortDateTime(e.date), 16))  \(eventDetail(e))")
            }
        }
        lines.append(String(repeating: "═", count: w))
        return lines.joined(separator: "\n")
    }

    private func buildJSON(_ events: [RecentEvent], ctx: ReportContext) -> String {
        let iso = ISO8601DateFormatter()
        let arr: [[String: Any]] = events.map { e in
            var d: [String: Any] = ["label": e.label, "type": e.type, "date": iso.string(from: e.date)]
            if !e.from.isEmpty    { d["from"]     = e.from }
            if !e.to.isEmpty      { d["to"]       = e.to }
            if !e.sizeStr.isEmpty { d["fileSize"]  = e.sizeStr }
            return d
        }
        let out: [String: Any] = [
            "generatedAt": iso.string(from: ctx.now),
            "days":        days,
            "eventCount":  events.count,
            "events":      arr
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func buildCSV(_ events: [RecentEvent]) -> String {
        var rows = [csvRow(["label", "eventType", "date", "fromVersion", "toVersion", "fileSize"])]
        for e in events {
            rows.append(csvRow([e.label, e.type, shortDateTime(e.date), e.from, e.to, e.sizeStr]))
        }
        return rows.joined(separator: "\n")
    }
}
