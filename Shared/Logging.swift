//
//  Logging.swift
//  patcher
//
//  Created by Gil Burns on 3/9/25.
//

import Foundation

class Logger {

    /// Set to true at startup (from the LogVerbose preference) to enable verbose output.
    /// When false, calls to `Logger.verbose()` are silently dropped.
    static var isVerbose: Bool = false

    /// Directory where log files are written.
    /// When the environment variable PATCHER_LOG_DIR is set, that path is used
    /// instead — allowing tests to redirect logs without requiring root access.
    static var logDirectory: URL = {
        let logPath: URL
        if let override = ProcessInfo.processInfo.environment["PATCHER_LOG_DIR"] {
            logPath = URL(fileURLWithPath: override)
        } else {
            logPath = FileManager.default.urls(for: .libraryDirectory, in: .localDomainMask).first!
                .appendingPathComponent("Logs")
                .appendingPathComponent("Patcher")
        }

        // Ensure the directory exists
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: logPath.path) {
            do {
                try fileManager.createDirectory(at: logPath, withIntermediateDirectories: true, attributes: [FileAttributeKey.posixPermissions: 0o755])
            } catch {
                fputs("Failed to create log directory at \(logPath.path): \(error.localizedDescription)\n", stderr)
            }
        }

        return logPath
    }()

    /// Logs a message only when verbose logging is enabled.
    /// Use for high-frequency or low-signal output (key-value dumps, per-label field lists, etc.)
    static func verbose(_ message: String, logType: String = "General") {
        guard isVerbose else { return }
        log(message, logType: logType)
    }

    /// True when running inside an XCTest / Swift Testing host process.
    /// Detected via environment variables injected by the test runner.
    private static let isTestEnvironment: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
    }()

    /// Logs a message to a specific log file determined by the `logType`.
    static func log(_ message: String, logType: String = "General") {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let currentDate = dateFormatter.string(from: Date())

        let timestampFormatter = DateFormatter()
        timestampFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss:SSS"
        let timestamp = timestampFormatter.string(from: Date())

        let logMessage = "[\(timestamp)] \(message)"
        let logFilePath = logDirectory.appendingPathComponent("Patcher_\(logType)_\(currentDate).log")

        // Only write to stdout when a terminal is attached (interactive use).
        // When running as a LaunchDaemon, stdout is /dev/null — skip the syscall.
        if isatty(STDOUT_FILENO) != 0 { print(logMessage) }

        // In test environments, skip file I/O unless PATCHER_LOG_DIR is explicitly set.
        // print() above already delivers output to the Xcode test console.
        if isTestEnvironment && ProcessInfo.processInfo.environment["PATCHER_LOG_DIR"] == nil {
            return
        }

        do {
            let fileManager = FileManager.default
            
            if !fileManager.fileExists(atPath: logFilePath.path) {
                fileManager.createFile(atPath: logFilePath.path, contents: nil, attributes: [FileAttributeKey.posixPermissions: 0o644])
            }

            let fileHandle = try FileHandle(forWritingTo: logFilePath)
            fileHandle.seekToEndOfFile()
            if let data = logMessage.appending("\n").data(using: .utf8) {
                fileHandle.write(data)
            }
            fileHandle.closeFile()
        } catch {
            fputs("Failed to write log: \(error.localizedDescription)\n", stderr)
        }
    }
}

// Usage Examples
/*
 Logger.log("Application started.")
 Logger.log("Update completed successfully.", logType: "Updates")
 Logger.log("An error occurred in the update process.", logType: "Errors")
*/
