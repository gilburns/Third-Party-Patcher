//
//  DeferralsReporter.swift
//  patcherreport
//
//  Created by Gil Burns on 4/19/26.
//
//  patcherreport deferrals [--days N]
//
//  Shows per-label dialog interaction history: every deferral, blocking-process
//  outcome, forced deadline, and user-continue event.  Intended to give admins
//  a verifiable record when a user claims they never saw a patching notification.
//

import Foundation

// MARK: - Event type set

private let dialogEventTypes: Set<String> = [
    LabelHistoryEvent.EventType.userContinued,
    LabelHistoryEvent.EventType.userDeferred,
    LabelHistoryEvent.EventType.timedOutDeferred,
    LabelHistoryEvent.EventType.deadlineForced,
    LabelHistoryEvent.EventType.blockingProcessNotified,
    LabelHistoryEvent.EventType.blockingProcessSkipped,
    LabelHistoryEvent.EventType.blockingProcessTimedOut,
    LabelHistoryEvent.EventType.blockingProcessQuit,
]


// MARK: - DeferralsReporter

struct DeferralsReporter {
    let days:   Int?
    let format: OutputFormat

    func run(to path: String?) {
        let ctx = ReportContext()
        switch format {
        case .table: emit(buildTable(ctx), to: path)
        case .json:  emit(buildJSON(ctx),  to: path)
        case .csv:   emit(buildCSV(ctx),   to: path)
        }
    }

    // MARK: Data

    private func cutoff(now: Date) -> Date? {
        guard let d = days else { return nil }
        return Calendar.current.date(byAdding: .day, value: -d, to: now)
    }

    /// Returns labels that have at least one dialog event within the optional date window,
    /// sorted by the date of their most recent dialog event (newest first).
    private func labelDialogEvents(_ ctx: ReportContext) -> [(label: String, events: [LabelHistoryEvent])] {
        let cut = cutoff(now: ctx.now)
        return ctx.histories.compactMap { (label, history) -> (String, [LabelHistoryEvent])? in
            var evts = history.events.filter { dialogEventTypes.contains($0.type) }
            if let cut { evts = evts.filter { $0.date >= cut } }
            return evts.isEmpty ? nil : (label, evts)
        }.sorted { a, b in
            (a.events.last?.date ?? .distantPast) > (b.events.last?.date ?? .distantPast)
        }
    }

    // MARK: Table

    private func buildTable(_ ctx: ReportContext) -> String {
        let w = 80
        var lines: [String] = []
        lines.append(String(repeating: "═", count: w))
        let dayStr = days.map { " (last \($0) days)" } ?? ""
        lines.append(" Dialog Interactions Report\(dayStr)  —  \(shortDateTime(ctx.now))")
        lines.append(String(repeating: "═", count: w))

        let labelsWithEvents = labelDialogEvents(ctx)

        guard !labelsWithEvents.isEmpty else {
            lines.append(" No dialog interaction history found\(dayStr).")
            lines.append(String(repeating: "═", count: w))
            return lines.joined(separator: "\n")
        }

        let totalDeferrals = labelsWithEvents.reduce(0) { sum, item in
            sum + item.events.filter {
                $0.type == LabelHistoryEvent.EventType.userDeferred ||
                $0.type == LabelHistoryEvent.EventType.timedOutDeferred
            }.count
        }
        let forcedCount = labelsWithEvents.filter { item in
            item.events.contains { $0.type == LabelHistoryEvent.EventType.deadlineForced }
        }.count

        lines.append(" \(labelsWithEvents.count) label(s)  ·  \(totalDeferrals) deferral(s)  ·  \(forcedCount) deadline(s) forced")

        for (label, events) in labelsWithEvents {
            let deferCount = events.filter {
                $0.type == LabelHistoryEvent.EventType.userDeferred ||
                $0.type == LabelHistoryEvent.EventType.timedOutDeferred
            }.count
            let forced = events.contains { $0.type == LabelHistoryEvent.EventType.deadlineForced }

            var header = " \(label)"
            var tags: [String] = []
            if deferCount > 0 { tags.append("\(deferCount) deferral\(deferCount == 1 ? "" : "s")") }
            if forced          { tags.append("deadline forced") }
            if !tags.isEmpty   { header += "  (\(tags.joined(separator: " · ")))" }

            lines.append("")
            lines.append(header)
            lines.append(" " + String(repeating: "─", count: w - 1))

            for event in events {
                let detail = labelEventDetail(event)
                lines.append("  \(col(shortDateTime(event.date), 16))  \(col(event.type, 24))  \(detail)")
            }
        }

        lines.append("")
        lines.append(String(repeating: "═", count: w))
        return lines.joined(separator: "\n")
    }

    // MARK: JSON

    private func buildJSON(_ ctx: ReportContext) -> String {
        let iso = ISO8601DateFormatter()
        let labelsWithEvents = labelDialogEvents(ctx)

        let arr: [[String: Any]] = labelsWithEvents.map { (label, events) in
            let evts: [[String: Any]] = events.map { event in
                var d: [String: Any] = ["type": event.type, "date": iso.string(from: event.date)]
                if let v = event.deferralMinutes     { d["deferralMinutes"]     = v }
                if let v = event.blockingProcessName { d["blockingProcessName"] = v }
                return d
            }
            let deferCount = events.filter {
                $0.type == LabelHistoryEvent.EventType.userDeferred ||
                $0.type == LabelHistoryEvent.EventType.timedOutDeferred
            }.count
            let forced = events.contains { $0.type == LabelHistoryEvent.EventType.deadlineForced }
            return ["label": label, "deferralCount": deferCount, "deadlineForced": forced, "events": evts]
        }

        let out: [String: Any] = [
            "generatedAt": iso.string(from: ctx.now),
            "labels":      arr,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: CSV

    private func buildCSV(_ ctx: ReportContext) -> String {
        let labelsWithEvents = labelDialogEvents(ctx)
        var rows = [csvRow(["label", "date", "eventType", "deferralMinutes", "blockingProcessName"])]
        for (label, events) in labelsWithEvents {
            for event in events {
                rows.append(csvRow([
                    label,
                    shortDateTime(event.date),
                    event.type,
                    event.deferralMinutes.map    { "\($0)" } ?? "",
                    event.blockingProcessName    ?? "",
                ]))
            }
        }
        return rows.joined(separator: "\n")
    }
}
