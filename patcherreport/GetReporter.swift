//
//  GetReporter.swift
//  patcherreport
//
//  patcherreport get <key> [--from summary|pending|deferrals|broken|deadline] [--days N]
//
//  Prints a single scalar value from one of the JSON report payloads, with no
//  quoting or wrapping. Intended for Jamf Extension Attributes and other scripts
//  that would otherwise have to parse `--json` output with a tool that isn't on a
//  stock macOS install.
//
//  The <key> is a dotted path into the JSON object, e.g.
//    patcherreport get updateRequired
//    patcherreport get deadline.daysUntilHardDeadline
//    patcherreport get lastApply.lastRun
//    patcherreport get totals.deferrals --from deferrals --days 30
//
//  A key that resolves to an array of scalars is printed one item per line.
//  Exit status is 1 (with a message on stderr) when the key is missing or
//  resolves to an object.
//

import Foundation

struct GetReporter {
    let key:    String
    let source: String
    let days:   Int?

    static let validSources = ["summary", "pending", "deferrals", "broken", "deadline"]

    func run(to path: String?) {
        let ctx = ReportContext()

        let object: [String: Any]
        switch source {
        case "summary":
            object = SummaryReporter(format: .json).jsonObject(ctx)
        case "pending":
            object = PendingReporter(format: .json).jsonObject(ctx)
        case "deferrals":
            object = DeferralsReporter(days: days, format: .json).jsonObject(ctx)
        case "broken":
            object = BrokenReporter(format: .json).jsonObject(ctx)
        case "deadline":
            object = DeadlineSummary(ctx, pendingItems: buildPendingItems(ctx)).jsonObject()
        default:
            fputs("patcherreport: unknown --from source '\(source)' (expected \(Self.validSources.joined(separator: ", ")))\n", stderr)
            exit(1)
        }

        guard let value = lookup(key, in: object) else {
            fputs("patcherreport: key '\(key)' not found in '\(source)'\n", stderr)
            exit(1)
        }

        guard let rendered = render(value) else {
            fputs("patcherreport: key '\(key)' refers to an object, not a scalar — specify a sub-key\n", stderr)
            exit(1)
        }

        emit(rendered, to: path)
    }

    // MARK: - Path lookup

    /// Walks a dotted key path through nested dictionaries.
    private func lookup(_ path: String, in object: [String: Any]) -> Any? {
        var current: Any = object
        for component in path.split(separator: ".").map(String.init) {
            guard let dict = current as? [String: Any], let next = dict[component] else { return nil }
            current = next
        }
        return current
    }

    // MARK: - Rendering

    /// Renders a scalar (or array of scalars) to plain text. Returns nil for objects.
    private func render(_ value: Any) -> String? {
        switch value {
        case let s as String:
            return s
        case let b as Bool:
            return b ? "true" : "false"
        case let n as Int:
            return "\(n)"
        case let n as Double:
            return "\(n)"
        case let n as NSNumber:
            return n.stringValue
        case let array as [Any]:
            let parts = array.compactMap { render($0) }
            return parts.count == array.count ? parts.joined(separator: "\n") : nil
        default:
            return nil
        }
    }
}
