//
//  ZshScriptRunner.swift
//  patcher
//
//  Created by Gil Burns on 3/9/25.
//

import Foundation

class ZshScriptRunner {
    
    /// Writes the provided Zsh script to a temporary file for execution.
    /// - Parameter scriptContents: The Zsh script as a string.
    /// - Returns: The URL of the script file, or `nil` if writing fails.
    static func writeScriptToFile(_ scriptContents: String) -> URL? {
        let tempScriptURL = AppConstants.patcherTempFolderURL
            .appendingPathComponent("process_label.sh")

        do {
            // Write script to a temporary file
            try scriptContents.write(to: tempScriptURL, atomically: true, encoding: .utf8)
            
            // Set execute permissions
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempScriptURL.path)
            
            Logger.verbose("✅ Script written to: \(tempScriptURL.path)")
            return tempScriptURL
        } catch {
            Logger.log("❌ Error writing script to file: \(error)")
            return nil
        }
    }

    /// Runs a Zsh script from a given file path with optional arguments and a timeout.
    /// - Parameters:
    ///   - scriptPath: The file path to the Zsh script.
    ///   - arguments: Optional arguments passed to the script.
    ///   - timeout: Maximum execution time in seconds (default: 30).
    /// - Returns: The script output as a string, or `nil` if an error occurs or timeout is reached.
    /// GitHub token from the `GitHubToken` preference, read once per process.
    /// Handed to label scripts only through the child environment (as GH_TOKEN) —
    /// never as an argument (visible in `ps`) or written into the script file.
    /// An expired or revoked token gets HTTP 401 on every API call — worse than no token —
    /// so it is checked once against /rate_limit (which doesn't count against the limit)
    /// and dropped if GitHub rejects it.
    private static let gitHubToken: String? = {
        guard let token = Preferences().gitHubToken else { return nil }
        switch checkGitHubToken(token) {
        case .accepted(let remaining, let limit):
            Logger.log("🔑 GitHubToken accepted — \(remaining) of \(limit) GitHub API requests remaining this hour")
            return token
        case .rejected(let status):
            Logger.log("⚠️ GitHubToken rejected by GitHub (HTTP \(status)) — expired or revoked? Label GitHub API requests will be unauthenticated (60/hour per IP).")
            return nil
        case .unverified(let reason):
            Logger.log("⚠️ Could not verify GitHubToken (\(reason)) — using it anyway")
            return token
        }
    }()

    private enum GitHubTokenCheck {
        case accepted(remaining: Int, limit: Int)
        case rejected(status: Int)
        case unverified(String)
    }

    private static func checkGitHubToken(_ token: String) -> GitHubTokenCheck {
        var request = URLRequest(url: URL(string: "https://api.github.com/rate_limit")!, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        var result: GitHubTokenCheck = .unverified("no response")
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .unverified(error.localizedDescription)
                return
            }
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 401 {
                result = .rejected(status: 401)
            } else if http.statusCode == 200 {
                let remaining = Int(http.value(forHTTPHeaderField: "x-ratelimit-remaining") ?? "") ?? -1
                let limit = Int(http.value(forHTTPHeaderField: "x-ratelimit-limit") ?? "") ?? -1
                result = .accepted(remaining: remaining, limit: limit)
            } else {
                result = .unverified("HTTP \(http.statusCode)")
            }
        }.resume()
        _ = semaphore.wait(timeout: .now() + 15)
        return result
    }

    /// Outcome of one script run.
    struct ScriptResult {
        /// Trimmed stdout+stderr, or nil when the run timed out.
        let output: String?
        let timedOut: Bool
        /// The script's exit status; nil when it timed out or could not be launched.
        let exitStatus: Int32?
    }

    /// Runs a script and returns its output, or nil on timeout.
    static func runScript(at scriptPath: String, arguments: [String] = [], timeout: TimeInterval = 30) -> String? {
        runScriptResult(at: scriptPath, arguments: arguments, timeout: timeout).output
    }

    /// Runs a script and reports whether it timed out and how it exited, so callers can
    /// tell a label that hung apart from one that exited deliberately without output.
    static func runScriptResult(at scriptPath: String, arguments: [String] = [], timeout: TimeInterval = 30) -> ScriptResult {
        let process = Process()
        process.launchPath = "/bin/zsh"
        process.arguments = [scriptPath] + arguments
        if let token = gitHubToken {
            var environment = ProcessInfo.processInfo.environment
            environment["GH_TOKEN"] = token
            process.environment = environment
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let group = DispatchGroup()
        group.enter()

        var launched = false
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try process.run()
                launched = true
                process.waitUntilExit()
            } catch {
                Logger.log("❌ Error running script: \(error)")
            }
            group.leave()
        }

        // Wait for process to complete or timeout
        let result = group.wait(timeout: .now() + timeout)

        // If timeout occurred, terminate the process
        if result == .timedOut {
            Logger.log("⏳ Timeout reached: Killing script process.")
            process.terminate()
            return ScriptResult(output: nil, timedOut: true, exitStatus: nil)
        }

        // Read output
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        let outputString = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ScriptResult(output: outputString, timedOut: false,
                            exitStatus: launched ? process.terminationStatus : nil)
    }
}

// MARK: - Example Usage
/*
 
 // RUN THIS ONCE
 if let scriptURL = ZshScriptRunner.writeScriptToFile(AppConstants.processLabelZsh) {
     print("Script file ready at: \(scriptURL.path)")
 }
 
// RUN THIS FOR EACH SH FILE
 if let scriptPath = scriptURL?.path {
     for labelFile in labelFiles {
         if let output = ZshScriptRunner.runScript(at: scriptPath, arguments: [labelFile]) {
             print("✅ Processed label \(labelFile):\n\(output)")
         } else {
             print("❌ Failed to process label \(labelFile)")
         }
     }
 }
 
 
 */
