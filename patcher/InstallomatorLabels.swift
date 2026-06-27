//
//  InstallomatorLabels.swift
//  patcher
//
//  Created by Gil Burns on 1/5/25.
//

import Foundation

class InstallomatorLabels {
    static func compareInstallomatorVersion(completion: @escaping (Bool, String) -> Void) {
        let prefs = Preferences()
        let account = prefs.installomatorGitHubAccount
        let repo    = prefs.installomatorGitHubRepo
        let branch  = prefs.installomatorGitHubBranch

        // URL to fetch the latest version
        let installomatorCurrentVersionURL = URL(string: "https://raw.githubusercontent.com/\(account)/\(repo)/refs/heads/\(branch)/Installomator.sh")!

        let installomatorLocalVersionPath = AppConstants.installomatorVersionFileURL
            .path

        Task {
            do {
                // Fetch the latest version from the web
                let (data, _) = try await URLSession.shared.data(from: installomatorCurrentVersionURL)
                Logger.log("Decoding Installomator web content for current version.", logType: "Updates")
                guard let content = String(data: data, encoding: .utf8) else {
                    Logger.log("Failed to decode Installomator web content", logType: "Updates")
                    completion(false, "Failed to decode Installomator web content")
                    return
                }
                Logger.log("Successfully decoded Installomator web content", logType: "Updates")


                // Extract the VERSIONDATE= value using regex
                let regex = try NSRegularExpression(pattern: #"VERSIONDATE="([^"]*)"#)
                guard let match = regex.firstMatch(in: content, options: [], range: NSRange(content.startIndex..<content.endIndex, in: content)),
                      let versionRange = Range(match.range(at: 1), in: content) else {
                    Logger.log("Failed to extract VERSIONDATE", logType: "Updates")
                    completion(false, "Failed to extract VERSIONDATE")
                    return
                }

                let installomatorCurrentVersion = content[versionRange]
                Logger.log("Found Installomator current version: \(installomatorCurrentVersion)", logType: "Updates")
                
                // Get the local version
                let installomatorLocalVersion: String
                if FileManager.default.fileExists(atPath: installomatorLocalVersionPath) {
                    installomatorLocalVersion = try String(contentsOfFile: installomatorLocalVersionPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    installomatorLocalVersion = "1990-01-01"
                }

                Logger.log("Found Installomator local version: \(installomatorLocalVersion)", logType: "Updates")

                // Convert dates to comparable formats
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd"

                guard let currentVersionDate = dateFormatter.date(from: String(installomatorCurrentVersion)),
                      let localVersionDate = dateFormatter.date(from: installomatorLocalVersion) else {
                    Logger.log("Failed to parse Installomator version dates", logType: "Updates")
                    completion(false, "Failed to parse Installomator version dates")
                    return
                }

                // Compare versions
                if currentVersionDate > localVersionDate {
                    Logger.verbose("New version available")
                    completion(false, "New Installomator version available: \(installomatorCurrentVersion)") // Online version is newer
                } else {
                    Logger.verbose("No new version available")
                    completion(true, "Installomator version is up to date: \(installomatorLocalVersion)") // Local version is up to date
                }
            } catch {
                Logger.log("Error comparing Installomator versions: \(error.localizedDescription)", logType: "Updates")
                completion(false, "Error: \(error.localizedDescription)")
            }
        }
    }

    static func installInstallomatorLabels(completion: @escaping (Bool, String) -> Void) {
        let prefs = Preferences()
        let account = prefs.installomatorGitHubAccount
        let repo    = prefs.installomatorGitHubRepo
        let branch  = prefs.installomatorGitHubBranch

        let tempDir = AppConstants.patcherTempFolderURL
            .appendingPathComponent("\(UUID().uuidString)")

        if !FileManager.default.fileExists(atPath: tempDir.path) {
            do {
                try FileManager.default.createDirectory(atPath: tempDir.path, withIntermediateDirectories: true, attributes: nil)
            } catch {
                Logger.log(error.localizedDescription);
                return
            }
        }

        let installomatorBranchURL = URL(string: "https://api.github.com/repos/\(account)/\(repo)/branches/\(branch)")!

        Task {
            do {
                // Fetch the branch SHA
                let (data, _) = try await URLSession.shared.data(from: installomatorBranchURL)
                guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                      let commit = json["commit"] as? [String: Any],
                      let sha = commit["sha"] as? String else {
                    Logger.log("Failed to fetch branch SHA", logType: "Updates")
                    completion(false, "Failed to fetch branch SHA")
                    return
                }

                Logger.verbose("SHA Value: \(sha)")
                // Download the tar.gz
                let installomatorURL = URL(string: "https://codeload.github.com/\(account)/\(repo)/legacy.tar.gz/\(sha)")!
                let installomatorTarGz = tempDir.appendingPathComponent("Installomator.tar.gz")
                let (tarGzData, _) = try await URLSession.shared.data(from: installomatorURL)
                try tarGzData.write(to: installomatorTarGz)

                // Extract the tar.gz
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                process.arguments = ["-xzf", installomatorTarGz.path, "-C", tempDir.path]
                try process.run()
                process.waitUntilExit()

                // Determine extracted directory
                guard let extractedDirName = try FileManager.default.contentsOfDirectory(atPath: tempDir.path).first(where: { $0.contains(sha.prefix(7)) }) else {
                    completion(false, "Failed to locate extracted directory")
                    return
                }

                let extractedDirURL = tempDir.appendingPathComponent(extractedDirName)

                // Copy the labels to destination
                let sourceDirectory = extractedDirURL
                    .appendingPathComponent("fragments")
                    .appendingPathComponent("labels")
                
                let destinationDirectory = AppConstants.installomatorLabelsFolderURL
                    .path

                try FileManager.default.createDirectory(atPath: destinationDirectory, withIntermediateDirectories: true, attributes: nil)
                if FileManager.default.fileExists(atPath: destinationDirectory) {
                    try FileManager.default.removeItem(atPath: destinationDirectory)
                }
                try FileManager.default.copyItem(atPath: sourceDirectory.path, toPath: destinationDirectory)

                // Get the Installomator.sh version
                let installomatorShPath = extractedDirURL.appendingPathComponent("Installomator.sh")
                let versionContent: String
                if FileManager.default.fileExists(atPath: installomatorShPath.path) {
                    let shContent = try String(contentsOf: installomatorShPath, encoding: .utf8)
                    let regex = try NSRegularExpression(pattern: #"VERSIONDATE="([^"]*)"#)
                    if let match = regex.firstMatch(in: shContent, options: [], range: NSRange(shContent.startIndex..<shContent.endIndex, in: shContent)),
                       let versionRange = Range(match.range(at: 1), in: shContent) {
                        versionContent = String(shContent[versionRange])
                    } else {
                        versionContent = "1990-01-01"
                    }
                } else {
                    versionContent = "1990-01-01"
                }

                // Save version to Version.txt
                let versionFilePath = AppConstants.installomatorVersionFileURL
                    .path

                try versionContent.write(toFile: versionFilePath, atomically: true, encoding: .utf8)
                
                do {
                    try FileManager.default.removeItem(atPath: tempDir.path)
//                    Logger.log("Deleted directory: \(tempDir.path)", logType: "Updates")
                } catch {
                    Logger.log("Failed to delete directory: \(error)", logType: "Updates")
                }

                completion(true, "Labels successfully updated to version \(versionContent)")
            } catch {
                Logger.log("Error installing labels: \(error.localizedDescription)", logType: "Updates")
                completion(false, "Error: \(error.localizedDescription)")
            }
        }
    }
}
