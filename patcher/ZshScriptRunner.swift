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
            
//            print("✅ Script written to: \(tempScriptURL.path)")
            return tempScriptURL
        } catch {
//            print("❌ Error writing script to file: \(error)")
            return nil
        }
    }

    /// Runs a Zsh script from a given file path with optional arguments and a timeout.
    /// - Parameters:
    ///   - scriptPath: The file path to the Zsh script.
    ///   - arguments: Optional arguments passed to the script.
    ///   - timeout: Maximum execution time in seconds (default: 30).
    /// - Returns: The script output as a string, or `nil` if an error occurs or timeout is reached.
    static func runScript(at scriptPath: String, arguments: [String] = [], timeout: TimeInterval = 30) -> String? {
        let process = Process()
        process.launchPath = "/bin/zsh"
        process.arguments = [scriptPath] + arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let group = DispatchGroup()
        group.enter()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
//                print("❌ Error running script: \(error)")
            }
            group.leave()
        }

        // Wait for process to complete or timeout
        let result = group.wait(timeout: .now() + timeout)

        // If timeout occurred, terminate the process
        if result == .timedOut {
//            print("⏳ Timeout reached: Killing script process.")
            process.terminate()
            return nil
        }

        // Read output
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        let outputString = String(data: outputData, encoding: .utf8)

        return outputString?.trimmingCharacters(in: .whitespacesAndNewlines)
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
