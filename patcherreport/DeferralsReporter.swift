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
//  Deferrals are broken out by how they occurred, matching the counters tracked
//  in deferral_state.json:
//    • user            — the user actively chose a defer duration in the prompt
//    • timed-out        — the prompt countdown expired and auto-deferred
//    • blocking-process — a label was skipped because its blocking process was running
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

// MARK: - Deferral categorisation

/// The three ways a deferral is recorded, mirroring `DeferralState` / `DeferralKind`.
enum DeferralCategory: String, CaseIterable {
    case user            = "user"
    case timedOut        = "timed-out"
    case blockingProcess = "blocking-process"

    /// JSON-friendly camelCase key.
    var jsonKey: String {
        switch self {
        case .user:            return "user"
        case .timedOut:        return "timedOut"
        case .blockingProcess: return "blockingProcess"
        }
    }
}

/// Maps a dialog event type to the deferral category it counts toward, or nil when
/// the event is not itself a deferral (e.g. the process was quit and patching proceeded).
func deferralCategory(for eventType: String) -> DeferralCategory? {
    switch eventType {
    case LabelHistoryEvent.EventType.userDeferred:
        return .user
    case LabelHistoryEvent.EventType.timedOutDeferred:
        return .timedOut
    case LabelHistoryEvent.EventType.blockingProcessSkipped,
         LabelHistoryEvent.EventType.blockingProcessNotified:
        return .blockingProcess
    default:
        return nil
    }
}

/// Per-category deferral tallies.
struct DeferralCounts {
    var user            = 0
    var timedOut        = 0
    var blockingProcess = 0

    var total: Int { user + timedOut + blockingProcess }

    mutating func add(_ category: DeferralCategory) {
        switch category {
        case .user:            user            += 1
        case .timedOut:        timedOut        += 1
        case .blockingProcess: blockingProcess += 1
        }
    }

    mutating func add(_ other: DeferralCounts) {
        user            += other.user
        timedOut        += other.timedOut
        blockingProcess += other.blockingProcess
    }

    subscript(_ category: DeferralCategory) -> Int {
        switch category {
        case .user:            return user
        case .timedOut:        return timedOut
        case .blockingProcess: return blockingProcess
        }
    }

    /// Non-zero categories as "2 user · 1 blocking-process".
    var breakdown: String {
        DeferralCategory.allCases
            .filter { self[$0] > 0 }
            .map { "\(self[$0]) \($0.rawValue)" }
            .joined(separator: " · ")
    }

    /// A human phrase for a per-label header:
    ///   "2 user deferrals"                                   (single category)
    ///   "4 deferrals (2 user · 1 timed-out · 1 blocking-process)"  (mixed)
    var tag: String {
        let nonZero = DeferralCategory.allCases.filter { self[$0] > 0 }
        guard total > 0 else { return "" }
        if nonZero.count == 1 {
            let c = nonZero[0]
            return "\(self[c]) \(c.rawValue) deferral\(self[c] == 1 ? "" : "s")"
        }
        return "\(total) deferrals (\(breakdown))"
    }
}

func deferralCounts(for events: [LabelHistoryEvent]) -> DeferralCounts {
    var counts = DeferralCounts()
    for event in events {
        if let category = deferralCategory(for: event.type) { counts.add(category) }
    }
    return counts
}


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

        var totals = DeferralCounts()
        for (_, events) in labelsWithEvents { totals.add(deferralCounts(for: events)) }

        let forcedCount = labelsWithEvents.filter { item in
            item.events.contains { $0.type == LabelHistoryEvent.EventType.deadlineForced }
        }.count

        let breakdown = totals.total > 0 ? " (\(totals.breakdown))" : ""
        lines.append(" \(labelsWithEvents.count) label(s)  ·  \(totals.total) deferral(s)\(breakdown)  ·  \(forcedCount) deadline(s) forced")

        for (label, events) in labelsWithEvents {
            let counts = deferralCounts(for: events)
            let forced = events.contains { $0.type == LabelHistoryEvent.EventType.deadlineForced }

            var header = " \(label)"
            var tags: [String] = []
            if counts.total > 0 { tags.append(counts.tag) }
            if forced           { tags.append("deadline forced") }
            if !tags.isEmpty    { header += "  (\(tags.joined(separator: ", ")))" }

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
        guard let data = try? JSONSerialization.data(
                withJSONObject: jsonObject(ctx),
                options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// The `deferrals --json` payload. Also consumed by the `get` subcommand.
    func jsonObject(_ ctx: ReportContext) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let labelsWithEvents = labelDialogEvents(ctx)

        var totals = DeferralCounts()
        var forcedTotal = 0

        let arr: [[String: Any]] = labelsWithEvents.map { (label, events) in
            let evts: [[String: Any]] = events.map { event in
                var d: [String: Any] = ["type": event.type, "date": iso.string(from: event.date)]
                if let c = deferralCategory(for: event.type) { d["deferralCategory"] = c.rawValue }
                if let v = event.deferralMinutes     { d["deferralMinutes"]     = v }
                if let v = event.blockingProcessName { d["blockingProcessName"] = v }
                return d
            }
            let counts = deferralCounts(for: events)
            let forced = events.contains { $0.type == LabelHistoryEvent.EventType.deadlineForced }
            totals.add(counts)
            if forced { forcedTotal += 1 }
            return [
                "label":          label,
                "deferralCount":  counts.total,
                "deferralsByType": [
                    "user":            counts.user,
                    "timedOut":        counts.timedOut,
                    "blockingProcess": counts.blockingProcess,
                ],
                "deadlineForced": forced,
                "events":         evts,
            ]
        }

        let out: [String: Any] = [
            "generatedAt": iso.string(from: ctx.now),
            "totals": [
                "labels":          arr.count,
                "deferrals":       totals.total,
                "user":            totals.user,
                "timedOut":        totals.timedOut,
                "blockingProcess": totals.blockingProcess,
                "deadlinesForced": forcedTotal,
            ],
            "labels": arr,
        ]
        return out
    }

    // MARK: CSV

    private func buildCSV(_ ctx: ReportContext) -> String {
        let labelsWithEvents = labelDialogEvents(ctx)
        var rows = [csvRow(["label", "date", "eventType", "deferralCategory", "deferralMinutes", "blockingProcessName"])]
        for (label, events) in labelsWithEvents {
            for event in events {
                rows.append(csvRow([
                    label,
                    shortDateTime(event.date),
                    event.type,
                    deferralCategory(for: event.type)?.rawValue ?? "",
                    event.deferralMinutes.map    { "\($0)" } ?? "",
                    event.blockingProcessName    ?? "",
                ]))
            }
        }
        return rows.joined(separator: "\n")
    }
}
