//
//  main.swift
//  patcherreport
//
//  Created by Gil Burns on 4/12/26.
//
//  Usage:
//    patcherreport summary                   Overall patching statistics
//    patcherreport recent [--days N]         Labels with activity in last N days (default 30)
//    patcherreport label <name>              Full chronological history for one label
//    patcherreport pending                   Labels staged but not yet applied
//    patcherreport never-updated             Labels discovered but never applied
//    patcherreport broken                    Broken scan and stage labels
//    patcherreport deferrals [--days N]      Dialog interaction history (deferrals, blocking-process)
//
//  Output options (apply to any subcommand):
//    --json                                  Output as JSON
//    --csv                                   Output as CSV
//    --output <path>                         Write to file instead of stdout
//

import Foundation

// MARK: - Entry point

let cliArgs = Array(CommandLine.arguments.dropFirst())

guard let subcommand = cliArgs.first, !subcommand.hasPrefix("-") else {
    printUsage(); exit(cliArgs.first == "--help" || cliArgs.first == "-h" ? 0 : 1)
}

let outputFormat: OutputFormat = cliArgs.contains("--json") ? .json
                                : cliArgs.contains("--csv")  ? .csv
                                : .table
let outputPath: String? = {
    guard let idx = cliArgs.firstIndex(of: "--output"), idx + 1 < cliArgs.count else { return nil }
    return cliArgs[idx + 1]
}()

switch subcommand {
case "summary":
    SummaryReporter(format: outputFormat).run(to: outputPath)

case "recent":
    let days = flagInt(cliArgs, flag: "--days") ?? 30
    RecentReporter(days: days, format: outputFormat).run(to: outputPath)

case "label":
    guard let name = cliArgs.dropFirst().first(where: { !$0.hasPrefix("-") }) else {
        fputs("patcherreport: 'label' requires a label name\n", stderr); exit(1)
    }
    LabelDetailReporter(label: name, format: outputFormat).run(to: outputPath)

case "pending":
    PendingReporter(format: outputFormat).run(to: outputPath)

case "never-updated":
    NeverUpdatedReporter(format: outputFormat).run(to: outputPath)

case "broken":
    BrokenReporter(format: outputFormat).run(to: outputPath)

case "deferrals":
    let days = flagInt(cliArgs, flag: "--days")
    DeferralsReporter(days: days, format: outputFormat).run(to: outputPath)

case "help":
    printUsage(); exit(0)

default:
    fputs("patcherreport: unknown subcommand '\(subcommand)'\n", stderr)
    printUsage(); exit(1)
}


// MARK: - Usage

func printUsage() {
    print("""
    Usage: patcherreport <subcommand> [options]

    Subcommands:
      summary                   Overall patching statistics
      recent [--days N]         Labels with activity in the last N days (default: 30)
      label <name>              Full chronological history for one label
      pending                   Labels staged but not yet applied
      never-updated             Labels discovered but never applied
      broken                    Broken scan and stage labels
      deferrals [--days N]      Dialog interaction history: deferrals, blocking-process outcomes

    Options:
      --json                    Output as JSON
      --csv                     Output as CSV
      --output <path>           Write output to a file instead of stdout
      --days N                  Days of history for 'recent' and 'deferrals' subcommands
    """)
}


// MARK: - Output

enum OutputFormat { case table, json, csv }

/// Writes output to stdout or a file. Creates parent directories as needed.
func emit(_ text: String, to path: String?) {
    guard let path else { print(text); return }
    do {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    } catch {
        fputs("patcherreport: failed to write '\(path)': \(error)\n", stderr)
        exit(1)
    }
}

// MARK: - Formatting helpers

func shortDateTime(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: date)
}

func shortDate(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
}

func formatMinutes(_ mins: Int) -> String {
    guard mins >= 60 else { return "\(mins) min" }
    let h = mins / 60, m = mins % 60
    return m == 0 ? "\(h) hr\(h == 1 ? "" : "s")" : "\(h)h \(m)m"
}

private func daysSince(_ date: Date, now: Date) -> Int {
    Calendar.current.dateComponents([.day], from: date, to: now).day ?? 0
}

/// Left-pads a string to exactly `width` characters, truncating if longer.
func col(_ s: String, _ width: Int) -> String {
    if s.count >= width { return String(s.prefix(width)) }
    return s + String(repeating: " ", count: width - s.count)
}

private func flagInt(_ args: [String], flag: String) -> Int? {
    guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
    return Int(args[idx + 1])
}

/// Wraps a CSV field in quotes if it contains commas, quotes, or newlines.
private func csvEscape(_ s: String) -> String {
    guard s.contains(",") || s.contains("\"") || s.contains("\n") else { return s }
    return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

func csvRow(_ fields: [String]) -> String {
    fields.map(csvEscape).joined(separator: ",")
}


// MARK: - Pending labels (shared by Summary and Pending reporters)

struct PendingItem {
    let label:            String
    let stagedVersion:    String
    let stagedDate:       Date
    let installedVersion: String
    let daysPending:      Int
}

func buildPendingItems(_ ctx: ReportContext) -> [PendingItem] {
    ctx.histories.compactMap { (label, history) -> PendingItem? in
        guard let lastStaged = history.lastEvent(ofType: LabelHistoryEvent.EventType.staged) else { return nil }
        if let lastApplied = history.lastEvent(ofType: LabelHistoryEvent.EventType.applied),
           lastApplied.date >= lastStaged.date { return nil }
        return PendingItem(
            label:            label,
            stagedVersion:    lastStaged.availableVersion ?? "",
            stagedDate:       lastStaged.date,
            installedVersion: ctx.discoveredPlists[label]?["installedVersion"] as? String ?? "",
            daysPending:      daysSince(lastStaged.date, now: ctx.now)
        )
    }.sorted { $0.daysPending > $1.daysPending }
}
