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
    static func activeBlocker() -> String? {
        if let process = activeDisplayAssertion() {
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
    /// Returns the process name of the first qualifying holder, or nil if none is active.
    static func activeDisplayAssertion() -> String? {
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

        return parseDisplayAssertion(from: output)
    }

    /// Parses `pmset -g assertions` output for lines that reference a display-preventing
    /// assertion type held by a non-system process.
    ///
    /// Relevant assertion types:
    ///   PreventUserIdleDisplaySleep  — most common (Zoom, Teams, Webex, …)
    ///   NoDisplaySleepAssertion      — stronger variant (Keynote full-screen, …)
    ///
    /// Per-process lines look like:
    ///   "   pid 1234(Keynote): [0x000c00…] 00:01:23 NoDisplaySleepAssertion named: "Presenting""
    private static func parseDisplayAssertion(from output: String) -> String? {
        let watchedTypes: Set<String> = [
            "PreventUserIdleDisplaySleep",
            "NoDisplaySleepAssertion"
        ]

        // System process names that legitimately hold these assertions without
        // indicating a user presentation.
        let ignoredProcesses: Set<String> = [
            "kernel_task", "powerd", "coreaudiod", "sharingd",
            "bluetoothd", "WindowServer", "tccd"
        ]

        for line in output.components(separatedBy: "\n") {
            // Only look at lines that mention a watched assertion type
            guard watchedTypes.contains(where: { line.contains($0) }) else { continue }

            // Extract the process name from the "pid NNNN(ProcessName):" prefix
            guard let openParen  = line.range(of: "("),
                  let closeRange = line.range(of: "):", range: openParen.upperBound..<line.endIndex) else {
                continue
            }
            let processName = String(line[openParen.upperBound..<closeRange.lowerBound])
            guard !processName.isEmpty, !ignoredProcesses.contains(processName) else { continue }

            return processName
        }
        return nil
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
