//
//  FocusDetector.swift
//  patcherscheduler
//
//  Created by Gil Burns on 4/10/26.
//
//  Detects system conditions that indicate the user should not be interrupted:
//    • A display-sleep prevention assertion (Keynote, Zoom screen share, etc.)
//    • macOS Focus / Do Not Disturb
//

import AppKit
import SystemConfiguration

struct FocusDetector {

    // MARK: - Public interface

    /// Returns a human-readable description of the active blocker, or nil if patching may proceed.
    /// - Parameter ignoredProcesses: Admin-configured process names (from
    ///   `Preferences.focusIgnoredProcesses`) that should not be treated as display-assertion
    ///   blockers, e.g. music players that legitimately prevent display sleep during playback.
    static func activeBlocker(ignoredProcesses: [String] = []) -> String? {
        if let process = activeDisplayAssertion(ignoredProcesses: ignoredProcesses) {
            return "display assertion held by '\(process)' (presentation / screen share active)"
        }
        if isFocusModeActive() {
            return "Focus / Do Not Disturb is active"
        }
        return nil
    }


    // MARK: - Display assertion

    /// Checks for an active display-sleep prevention assertion held by a user-facing process.
    /// Uses `pmset -g assertions` which enumerates all IOKit power assertions with their
    /// owning process names.
    ///
    /// Catches Keynote, Zoom, Webex, Teams, FaceTime, QuickTime screen recording, and any
    /// other app that calls `IOPMAssertionCreateWithName` to prevent display sleep.
    ///
    /// - Parameter ignoredProcesses: Admin-configured process names to exclude — see
    ///   `Preferences.focusIgnoredProcesses`. Matched case-insensitively against the resolved
    ///   process name.
    /// Returns a comma-separated list of every qualifying holder's process name (so the log can
    /// show, e.g., "PowerPoint, Zoom" when more than one is active), or nil if none is active.
    static func activeDisplayAssertion(ignoredProcesses: [String] = []) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Logger.log("⚠️ FocusDetector: could not run pmset: \(error)")
            return nil
        }

        let data   = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        let holders = parseDisplayAssertion(from: output, ignoredProcesses: ignoredProcesses)
        guard !holders.isEmpty else { return nil }
        return holders.joined(separator: ", ")
    }

    /// Parses `pmset -g assertions` output for lines that reference a display-preventing
    /// assertion type held by a non-system, non-ignored process.
    ///
    /// Relevant assertion types:
    ///   PreventUserIdleDisplaySleep  — most common (Zoom, Teams, Webex, …)
    ///   NoDisplaySleepAssertion      — stronger variant (Keynote full-screen, …)
    ///
    /// Per-process lines look like:
    ///   "   pid 1234(Keynote): [0x000c00…] 00:01:23 NoDisplaySleepAssertion named: "Presenting""
    ///
    /// The name pmset prints between parens can be truncated or a generic helper name, so the
    /// PID is also resolved through `ps` to get the assertion holder's real executable name
    /// before it's checked against `ignoredProcesses`.
    ///
    /// Scans every line rather than stopping at the first hit, so callers can log every
    /// distinct blocking process (e.g. PowerPoint and Zoom both holding assertions at once).
    private static func parseDisplayAssertion(from output: String, ignoredProcesses: [String]) -> [String] {
        let watchedTypes: Set<String> = [
            "PreventUserIdleDisplaySleep",
            "NoDisplaySleepAssertion"
        ]

        // System process names that legitimately hold these assertions without
        // indicating a user presentation.
        let systemIgnoredProcesses: Set<String> = [
            "kernel_task", "powerd", "coreaudiod", "sharingd",
            "bluetoothd", "WindowServer", "tccd"
        ]

        var holders: [String] = []

        for line in output.components(separatedBy: "\n") {
            // Only look at lines that mention a watched assertion type
            guard watchedTypes.contains(where: { line.contains($0) }) else { continue }

            // Extract the pid and process name from the "pid NNNN(ProcessName):" prefix
            guard let pidRange   = line.range(of: "pid "),
                  let openParen  = line.range(of: "(", range: pidRange.upperBound..<line.endIndex),
                  let closeRange = line.range(of: "):", range: openParen.upperBound..<line.endIndex) else {
                continue
            }
            let pidString   = String(line[pidRange.upperBound..<openParen.lowerBound])
            let processName = String(line[openParen.upperBound..<closeRange.lowerBound])
            guard !processName.isEmpty, !systemIgnoredProcesses.contains(processName) else { continue }

            // Resolve the real executable name behind the PID — pmset's own name can be
            // truncated or a generic sandboxed-helper name that doesn't match the admin's
            // ignore-list entry for the app the user actually sees (e.g. "Spotify").
            let resolvedName = pid(from: pidString).flatMap(processName(forPID:)) ?? processName

            if matches(processName: resolvedName, orFallback: processName, ignoredProcesses: ignoredProcesses) {
                Logger.log("ℹ️ FocusDetector: display assertion by '\(resolvedName)' ignored (matches FocusIgnoredProcesses).")
                continue
            }

            if !holders.contains(resolvedName) {
                holders.append(resolvedName)
            }
        }
        return holders
    }

    /// True if either the resolved process name or the raw pmset-reported name matches
    /// (case-insensitively, substring match) any entry in the admin-configured ignore list.
    private static func matches(processName resolvedName: String, orFallback fallbackName: String, ignoredProcesses: [String]) -> Bool {
        guard !ignoredProcesses.isEmpty else { return false }
        return ignoredProcesses.contains { ignored in
            resolvedName.localizedCaseInsensitiveContains(ignored) ||
            fallbackName.localizedCaseInsensitiveContains(ignored)
        }
    }

    private static func pid(from pidString: String) -> Int32? {
        Int32(pidString)
    }

    /// Resolves the executable name for a given PID via `ps`, returning just the last
    /// path component (e.g. "Spotify" from "/Applications/Spotify.app/Contents/MacOS/Spotify").
    /// Returns nil if the process has already exited or `ps` fails.
    private static func processName(forPID pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "comm="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty else {
            return nil
        }

        return (output as NSString).lastPathComponent
    }


    // MARK: - Focus / Do Not Disturb

    /// Returns true if the active console user has Focus or Do Not Disturb enabled.
    ///
    /// Reads `~/Library/DoNotDisturb/DB/Assertions.json`. When a Focus mode is active
    /// the system writes a live assertion into the `storeAssertionRecords` array inside
    /// one of the `data` entries. When Focus is turned off that record is moved to
    /// `storeInvalidationRecords` and `storeAssertionRecords` disappears.
    ///
    /// Because patcherscheduler runs as root we resolve the console user's home
    /// directory via the system password database and read the file directly.
    /// Returns true if the active console user has a Focus mode enabled that warrants
    /// deferring a patching install.
    ///
    /// Sleep Focus is explicitly excluded: if the Mac is actually asleep the
    /// LaunchDaemon will not fire at all, so Sleep Focus on an awake Mac means the
    /// user is away from the keyboard — an ideal time to patch, not defer.
    ///
    /// All other Focus modes (Do Not Disturb, Work, Personal, Gaming, custom, etc.)
    /// are treated as active-use signals and cause apply to be deferred.
    static func isFocusModeActive() -> Bool {
        guard let username = consoleUsername(),
              let homeDir  = homeDirectory(for: username) else { return false }

        let assertionsURL = homeDir
            .appendingPathComponent("Library")
            .appendingPathComponent("DoNotDisturb")
            .appendingPathComponent("DB")
            .appendingPathComponent("Assertions.json")

        guard let data      = try? Data(contentsOf: assertionsURL),
              let json      = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else {
            return false
        }

        // Walk every store entry and every active assertion record.
        for entry in dataArray {
            guard let records = entry["storeAssertionRecords"] as? [[String: Any]] else { continue }
            for record in records {
                guard let details   = record["assertionDetails"] as? [String: Any],
                      let modeID    = details["assertionDetailsModeIdentifier"] as? String else { continue }

                // Sleep Focus on an awake Mac is a patching opportunity, not a blocker.
                if modeID == "com.apple.sleep.sleep-mode" {
                    Logger.log("ℹ️ Focus: Sleep mode active — not blocking patching.")
                    continue
                }

                // Any other active Focus mode indicates the user may be at the keyboard.
                Logger.log("ℹ️ Focus: active mode '\(modeID)' — deferring.")
                return true
            }
        }
        return false
    }


    // MARK: - Helpers

    /// Returns the short login name of the current console (GUI) user, or nil if
    /// no user is logged in at the GUI.
    private static func consoleUsername() -> String? {
        SCDynamicStoreCopyConsoleUser(nil, nil, nil) as String?
    }

    /// Returns the home-directory URL for the given username via the system password database.
    private static func homeDirectory(for username: String) -> URL? {
        guard let pw = getpwnam(username) else { return nil }
        return URL(fileURLWithPath: String(cString: pw.pointee.pw_dir), isDirectory: true)
    }
}
